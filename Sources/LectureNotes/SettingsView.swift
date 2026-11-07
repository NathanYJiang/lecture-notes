import Speech
import SwiftUI

enum SettingsTab: Hashable { case audio, ai, style, drive, general }

struct SettingsView: View {
    var tab: SettingsTab

    var body: some View {
        switch tab {
        case .audio: AudioSettings()
        case .ai: AISettings()
        case .style: StyleSettings()
        case .drive: DriveSettings()
        case .general: GeneralSettings()
        }
    }
}

private struct Caption: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

private struct Field: View {
    var placeholder: String
    @Binding var text: String
    var secure = false

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .frame(width: 170)
    }
}

private struct AudioSettings: View {
    @EnvironmentObject var prefs: Prefs
    @State private var languages: [(id: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What gets recorded")
            Card {
                Row(icon: "waveform", tint: .orange, title: "Source") {
                    Picker("", selection: $prefs.audioSource) {
                        ForEach(AudioSource.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                CardDivider()
                Row(icon: "globe", tint: .teal, title: "Language", subtitle: "Spoken in the lecture") {
                    Picker("", selection: $prefs.localeID) {
                        ForEach(languages, id: \.id) { Text($0.name).tag($0.id) }
                        if !languages.contains(where: { $0.id == prefs.localeID }) {
                            Text(prefs.localeID).tag(prefs.localeID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
            }
            if prefs.audioSource == .micAndSystem {
                Caption("System audio captures Zoom, YouTube, etc. macOS asks for Screen & System Audio Recording permission the first time. Wear headphones so the mic doesn't pick up the same audio twice.")
            }
        }
        .task { await loadLanguages() }
    }

    private func loadLanguages() async {
        let supported = await SpeechTranscriber.supportedLocales
        languages = supported
            .map { (id: $0.identifier, name: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name < $1.name }
        // Snap a loose ID like "en-US" to the matching supported one ("en_US").
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: prefs.localeID)) {
            prefs.localeID = match.identifier
        }
    }
}

private struct AISettings: View {
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Who writes your notes")
            Card {
                Row(icon: "sparkles", tint: .purple, title: "Provider") {
                    Picker("", selection: $prefs.provider) {
                        ForEach(LLMProvider.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if prefs.provider.showsKeyField {
                    CardDivider()
                    Row(icon: "key.fill", tint: .yellow, title: "API key") {
                        Field(placeholder: "Paste key", text: $prefs.apiKey, secure: true)
                    }
                    if let keyURL = prefs.provider.keyURL, prefs.apiKey.isEmpty {
                        CardDivider()
                        Row(icon: "arrow.up.right.square", tint: .blue, title: prefs.provider == .gemini ? "Get a free key" : "Get a key") {
                            Link("Open", destination: keyURL).font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
                CardDivider()
                Row(icon: "cpu", tint: .blue, title: "Model") {
                    Field(placeholder: prefs.provider.defaultModel, text: $prefs.model)
                }
                CardDivider()
                Row(icon: "link", tint: .secondary, title: "Base URL") {
                    Field(placeholder: "https://…", text: $prefs.baseURL)
                }
            }
            Caption(prefs.provider == .gemini
                ? "Gemini is free with a Google account, no card needed. “gemini-flash-latest” always points at Google's newest Flash model. Free-tier prompts may be used by Google to improve its models."
                : "Keys are stored in your Keychain.")
        }
    }
}

private struct StyleSettings: View {
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "How your notes look") {
                Button("Reset") { prefs.stylePrompt = Prefs.defaultStylePrompt }
                    .font(.system(size: 12))
            }
            Card {
                TextEditor(text: $prefs.stylePrompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 300)
            }
            Caption("This is the instruction the AI follows. Ask for Cornell notes, a table, a different language — anything.")
        }
    }
}

private struct DriveSettings: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var google: Google
    @State private var error: String?
    @State private var working = false
    @State private var newFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Where notes go") {
                if working { ProgressView().controlSize(.small) }
            }
            if let email = google.email {
                Card {
                    Row(icon: "person.crop.circle.fill.badge.checkmark", tint: .green, title: "Signed in", subtitle: email) {
                        Button("Sign out") { google.signOut() }.controlSize(.small)
                    }
                    CardDivider()
                    Row(icon: "folder.fill", tint: .blue, title: "Save to") {
                        Picker("", selection: folderBinding) {
                            ForEach(google.folders) { Text($0.name).tag($0.id) }
                            if !google.folders.contains(where: { $0.id == prefs.folderID }) {
                                Text(prefs.folderName).tag(prefs.folderID)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    CardDivider()
                    Row(icon: "folder.badge.plus", tint: .secondary, title: "New folder") {
                        HStack(spacing: 6) {
                            TextField("e.g. CS 32", text: $newFolder)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .frame(width: 110)
                                .onSubmit(createFolder)
                            Button("Add", action: createFolder)
                                .controlSize(.small)
                                .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Caption("Folders are created in your My Drive. You can move them anywhere in Drive afterwards and the app will still save into them.")
            } else if !google.isConfigured {
                Card {
                    Row(icon: "doc.on.clipboard", tint: .blue, title: "Copy mode",
                        subtitle: "No sign-in needed")
                    CardDivider()
                    Text("When notes are ready, hit Copy notes and paste anywhere (Google Docs, Notion, Notes). Headings, bullets, and bold come with it. Notes are also saved on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                }
                Caption("Coming soon: sign in with Google and every lecture becomes a Doc in your Drive automatically.")
            } else {
                Card {
                    VStack(spacing: 10) {
                        Text("Notes are saved as Google Docs in a “Lecture Notes” folder in your Drive.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        GoogleSignInButton { run { try await google.signIn() } }
                    }
                    .padding(16)
                }
                Caption("The app can only see files it creates, never the rest of your Drive.")
            }
            if let error { Caption(error).foregroundStyle(.red) }
        }
        .task {
            if google.email != nil && google.folders.isEmpty { try? await google.loadFolders() }
        }
    }

    private var folderBinding: Binding<String> {
        Binding(
            get: { prefs.folderID },
            set: { id in
                prefs.folderID = id
                prefs.folderName = google.folders.first { $0.id == id }?.name ?? prefs.folderName
            }
        )
    }

    private func createFolder() {
        let name = newFolder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        run {
            let folder = try await google.createFolder(name)
            prefs.folderID = folder.id
            prefs.folderName = folder.name
            newFolder = ""
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        error = nil
        working = true
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

struct GoogleSignInButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("G")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.blue, .red, .yellow, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Sign in with Google").font(.system(size: 13.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "App")
            Card {
                Row(icon: "power", tint: .green, title: "Launch at login") {
                    Toggle("", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                CardDivider()
                Row(icon: "arrow.up.forward.app", tint: .blue, title: "Open Google Doc when done") {
                    Toggle("", isOn: $prefs.openDocWhenDone)
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                CardDivider()
                Row(icon: "folder", tint: .secondary, title: "Recordings", subtitle: "Audio, transcripts, notes") {
                    Button("Show") { state.showFiles(AppState.rootDir) }.controlSize(.small)
                }
                CardDivider()
                Row(icon: "info.circle", tint: .secondary, title: "Version") {
                    Value(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                }
            }
        }
    }
}
