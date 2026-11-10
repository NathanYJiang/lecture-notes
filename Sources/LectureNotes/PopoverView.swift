import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            header
                .frame(height: 30)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if state.showSettings {
                IconTabBar(items: [
                    TabItem(tag: SettingsTab.audio, icon: "mic", help: "Audio"),
                    TabItem(tag: .ai, icon: "sparkles", help: "AI"),
                    TabItem(tag: .style, icon: "text.alignleft", help: "Style"),
                    TabItem(tag: .drive, icon: "externaldrive", help: "Drive"),
                    TabItem(tag: .general, icon: "switch.2", help: "General"),
                ], selection: $state.settingsTab, showLabels: true)
                SettingsView(tab: state.settingsTab)
            } else {
                IconTabBar(items: [
                    TabItem(tag: Tab.record, icon: "record.circle", help: "Record"),
                    TabItem(tag: .transcript, icon: "text.quote", help: "Live transcript"),
                    TabItem(tag: .history, icon: "clock.arrow.circlepath", help: "History"),
                ], selection: $state.tab)
                switch state.tab {
                case .record: RecordPane()
                case .transcript: TranscriptPane()
                case .history: HistoryPane()
                }
            }

            if state.confirmingQuit {
                QuitConfirmation()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 12) {
                if state.showSettings {
                    FooterButton(title: "Quit", icon: "power") { state.requestQuit() }
                    FooterPrimaryButton(title: "Done", icon: "checkmark") { toggleSettings() }
                } else {
                    FooterButton(title: "Settings", icon: "gearshape") { toggleSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                    FooterButton(title: "Quit", icon: "power") { state.requestQuit() }
                }
            }
        }
        .padding(14)
        .frame(width: DS.width)
    }

    @ViewBuilder private var header: some View {
        if state.showSettings {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Brand.gradient)
                    .symbolEffect(.rotate, options: .nonRepeating, value: state.showSettings)
                Text("Settings")
                    .font(.system(size: 17, weight: .semibold))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
            LogoMark(size: 30)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private func toggleSettings() {
        withAnimation(.snappy(duration: 0.25)) { state.showSettings.toggle() }
    }
}

struct RecordPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var google: Google
    @State private var signInError: String?

    private var languageName: String {
        let code = Locale(identifier: prefs.localeID).language.languageCode?.identifier ?? prefs.localeID
        return Locale.current.localizedString(forLanguageCode: code) ?? prefs.localeID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: state.isRecording ? "Recording" : "Record") {
                Button { state.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Settings")
            }

            Card {
                meter
                CardDivider()
                inputRow(icon: "character.cursor.ibeam") {
                    TextField("Lecture title (optional)", text: $state.lectureTitle)
                        .textFieldStyle(.plain)
                }
                CardDivider()
                slidesRow

                CardDivider()
                Row(icon: "waveform", tint: .orange, title: "Audio", subtitle: prefs.audioSource.label) {
                    Value(languageName)
                }
                CardDivider()
                Row(icon: "sparkles", tint: .purple, title: "Notes by", subtitle: prefs.provider.label) {
                    Value(LLMProvider.displayName(for: prefs.model))
                }
                CardDivider()
                saveToRow

                if let signInError {
                    Text(signInError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }

                if let statusRow {
                    CardDivider()
                    statusRow
                }
            }

            PrimaryButton(
                title: state.isRecording ? "Stop  ·  \(state.elapsedString)" : "Start recording",
                icon: state.isRecording ? "stop.fill" : "record.circle.fill",
                tint: state.isRecording ? .red : Brand.indigo,
                action: state.toggleRecording
            )
            .disabled(state.phase.isBusy)
            .opacity(state.phase.isBusy ? 0.5 : 1)
        }
    }

    private var meter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: state.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 15))
                    .foregroundStyle(state.isRecording ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: state.isRecording)
                    .frame(width: 22)
                Text(state.isRecording ? "Live" : "Microphone").font(.system(size: 13.5))
                MeterLevelBar(meter: state.meter, tint: state.isRecording ? .red : .secondary)
                Text(state.elapsedString)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            MeterSparkline(meter: state.meter, tint: state.isRecording ? .red : .secondary.opacity(0.6))
                .frame(height: 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func inputRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            content().font(.system(size: 13.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var slidesRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(icon: "rectangle.stack.fill", tint: .teal, title: "Slides", subtitle: slidesSubtitle) {
                HStack(spacing: 8) {
                    if !state.slides.isEmpty {
                        Button { state.slides = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove slides")
                    }
                    Button(state.slides.isEmpty ? "Add" : "Add more") { state.chooseSlides() }
                        .controlSize(.small)
                }
            }
            if let error = state.slidesError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            state.addSlides(urls)
            return true
        }
        .help("Add or drag in the lecture's PDF. The transcriber learns its terms, and the AI uses it to get the notes right.")
    }

    private var slidesSubtitle: String {
        switch state.slides.count {
        case 0: "PDF · improves accuracy"
        case 1: state.slides[0].name
        default: "\(state.slides.count) files"
        }
    }

    @ViewBuilder private var saveToRow: some View {
        if let email = google.email {
            Row(icon: "folder.fill", tint: .blue, title: "Save to", subtitle: email) {
                Value(prefs.folderName)
            }
        } else if google.isConfigured {
            Row(icon: "folder.fill", tint: .blue, title: "Save to", subtitle: "Google Drive") {
                Button("Sign in") {
                    signInError = nil
                    Task {
                        do { try await google.signIn() } catch { signInError = error.localizedDescription }
                    }
                }
                .controlSize(.small)
            }
        } else {
            Row(icon: "doc.richtext.fill", tint: .blue, title: "Save to", subtitle: "Copy & paste") {
                Value("This Mac")
            }
        }
    }

    private var statusRow: AnyView? {
        switch state.phase {
        case .idle, .recording:
            if prefs.provider.needsKey && prefs.apiKey.isEmpty {
                return AnyView(Row(icon: "key.fill", tint: .orange, title: "Add an AI key",
                                   subtitle: prefs.provider == .gemini ? "Gemini is free" : prefs.provider.label) {
                    Button("Add key") { state.openSettings(.ai) }
                        .controlSize(.small)
                })
            }
            return nil
        case .preparing, .finishing, .transcribing, .summarizing, .uploading:
            return AnyView(Row(icon: "hourglass", tint: Brand.indigo, title: state.phase.label) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if state.canCancel {
                        Button("Cancel", action: state.cancelProcessing)
                            .controlSize(.small)
                    }
                }
            })
        case .done(let url):
            if let url {
                return AnyView(Row(icon: "checkmark.circle.fill", tint: .green, title: "Notes saved", subtitle: prefs.folderName) {
                    Link(destination: url) {
                        Label("Open", systemImage: "arrow.up.right").font(.system(size: 13, weight: .semibold))
                    }
                })
            }
            return AnyView(VStack(spacing: 0) {
                Row(icon: "checkmark.circle.fill", tint: .green, title: "Notes ready",
                    subtitle: "Paste into Google Docs, Notion, anywhere")
                if let uploadError = state.uploadError {
                    Text(uploadError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 48)
                        .padding(.trailing, 14)
                        .padding(.bottom, 8)
                }
                HStack(spacing: 8) {
                    CopyNotesButton { state.copyNotes() }
                    SmallActionButton(title: "View", icon: "eye") { state.openNotes() }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            })
        case .failed(let message):
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                Row(icon: "exclamationmark.triangle.fill", tint: .orange,
                    title: state.canRetry ? "Couldn't make notes" : "Something went wrong")
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 48)
                    .padding(.trailing, 14)
                    .padding(.top, -4)
                    .padding(.bottom, 10)
                HStack(spacing: 8) {
                    if state.canRetry {
                        SmallActionButton(title: "Retry", icon: "arrow.clockwise", prominent: true, action: state.retry)
                    }
                    SmallActionButton(title: "Dismiss", icon: "xmark") { state.phase = .idle }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            })
        }
    }
}

/// Copy button that briefly confirms with "Copied".
struct CopyNotesButton: View {
    var action: () -> Void
    @State private var copied = false

    var body: some View {
        SmallActionButton(title: copied ? "Copied!" : "Copy notes",
                          icon: copied ? "checkmark" : "doc.on.clipboard",
                          prominent: true) {
            action()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }
}

struct QuitConfirmation: View {
    @EnvironmentObject var state: AppState

    private var title: String {
        switch state.phase {
        case .recording: "You're still recording"
        case .preparing: "A recording is starting"
        case .finishing: "Saving your recording"
        default: "Notes are still being made"
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .recording: "Save it first so the lecture isn't lost"
        case .finishing: "It'll finish saving before quitting"
        default: "You can finish later from History"
        }
    }

    var body: some View {
        Card {
            Row(icon: "exclamationmark.triangle.fill", tint: .orange, title: title, subtitle: subtitle)
            HStack(spacing: 8) {
                SmallActionButton(title: "Cancel", icon: "xmark") {
                    withAnimation(.snappy(duration: 0.2)) { state.confirmingQuit = false }
                }
                if state.isRecording {
                    SmallActionButton(title: "Save & Quit", icon: "square.and.arrow.down", prominent: true) { state.saveAndQuit() }
                } else {
                    SmallActionButton(title: "Quit anyway", icon: "power", prominent: true) { NSApp.terminate(nil) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }
}

struct SmallActionButton: View {
    var title: String
    var icon: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(prominent ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TranscriptPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TranscriptCard(live: state.live, isRecording: state.isRecording)
            if state.liveInterrupted && state.isRecording {
                Label("macOS's speech service stopped, so the live transcript paused. Recording continues, and the full transcript is made from the audio after you stop.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct TranscriptCard: View {
    @ObservedObject var live: LiveTranscript
    var isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Live transcript") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(live.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help("Copy transcript")
                .disabled(live.chunks.isEmpty)
            }

            Card {
                Row(icon: "text.word.spacing", tint: .teal, title: "Words",
                    subtitle: isRecording ? "Transcribing on-device" : "On-device, private") {
                    Value("\(live.wordCount)")
                }
                CardDivider()
                if live.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text(isRecording ? "Listening…" : "Start recording and the transcript\nappears here as you go.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(live.chunks.enumerated()), id: \.offset) { _, chunk in
                                Text(chunk)
                            }
                            ForEach(live.volatile.keys.sorted(), id: \.self) { key in
                                Text(live.volatile[key] ?? "").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
                    }
                    .defaultScrollAnchor(.bottom)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: 300)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: DS.cardRadius, bottomTrailingRadius: DS.cardRadius))
                }
            }
        }
    }
}

struct MeterLevelBar: View {
    @ObservedObject var meter: LevelMeter
    var tint: Color

    var body: some View {
        LevelBar(value: meter.levels.last ?? 0, tint: tint)
    }
}

struct MeterSparkline: View {
    @ObservedObject var meter: LevelMeter
    var tint: Color

    var body: some View {
        Sparkline(values: meter.levels, tint: tint)
    }
}

struct HistoryPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let dir = state.openLecture, let record = state.history.first(where: { $0.dir == dir }) {
            LectureDetail(record: record)
                .id(dir)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "History") {
                if !state.history.isEmpty {
                    Text("\(state.history.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                Button { state.showFiles(AppState.rootDir) } label: { Image(systemName: "folder") }
                    .help("Open recordings folder")
            }

            Card {
                if state.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("No lectures yet.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                } else {
                    HistoryList(records: state.history)
                        .equatable()
                }
            }
            if !state.history.isEmpty {
                Text("Click a lecture to open it. Right-click for more options.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { state.loadHistory() }
    }
}

struct HistoryList: View, Equatable {
    let records: [LectureRecord]

    static let rowHeight: CGFloat = 50
    static let maxVisibleRows: CGFloat = 6.5

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    HistoryRow(record: record)
                        .frame(height: Self.rowHeight)
                        .overlay(alignment: .top) { if index > 0 { CardDivider() } }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(height: min(CGFloat(records.count), Self.maxVisibleRows) * Self.rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
    }
}

struct HistoryRow: View {
    let record: LectureRecord
    @State private var hovering = false

    private var state: AppState { .shared }

    var body: some View {
        Row(icon: record.hasNotes ? "doc.text.fill" : "waveform",
            tint: record.hasNotes ? .blue : .secondary,
            title: title, subtitle: subtitle) {
            Group {
                if let docURL = record.docURL {
                    Link(destination: docURL) { Image(systemName: "arrow.up.right") }
                        .help("Open Google Doc")
                } else if record.hasNotes {
                    CopyIconButton { state.copyNotes(record.dir) }
                } else {
                    Button { state.regenerate(record, retranscribe: false) } label: { Image(systemName: "sparkles") }
                        .help("Make notes")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 24)
        }
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.openLecture = record.dir }
        .contextMenu {
            Button("Open") { state.openLecture = record.dir }
            Button("Rename…") {
                state.renameRequested = true
                state.openLecture = record.dir
            }
            Divider()
            if let docURL = record.docURL { Link("Open Google Doc", destination: docURL) }
            if record.hasNotes {
                Button("View notes") { state.openNotes(record.dir) }
                Button("Copy notes") { state.copyNotes(record.dir) }
            }
            Divider()
            Button(record.hasNotes ? "Make notes again" : "Make notes") { state.regenerate(record, retranscribe: false) }
            Button("Re-transcribe") { state.regenerate(record, retranscribe: true) }
            Button("Add slides & re-transcribe…") { state.addSlidesAndRetranscribe(record) }
            Divider()
            Button("Show in Finder") { state.showFiles(record.dir) }
        }
    }

    private var title: String { record.name }

    private var subtitle: String {
        var text = record.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let duration = record.meta.duration { text += "  ·  " + AppState.format(duration) }
        if let count = record.meta.important?.count, count > 0 { text += "  ·  ⚑ \(count) important" }
        return text
    }
}

struct CopyIconButton: View {
    var action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? .green : .secondary)
        }
        .help("Copy notes")
    }
}
