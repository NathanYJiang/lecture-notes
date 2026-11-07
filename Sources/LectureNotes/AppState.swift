import AppKit
import SwiftUI
import Foundation
import ServiceManagement

enum Phase: Equatable {
    case idle, preparing, recording, finishing, transcribing, summarizing, uploading
    case done(URL?)
    case failed(String)

    var isBusy: Bool { [.preparing, .finishing, .transcribing, .summarizing, .uploading].contains(self) }

    var label: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Loading speech model…"
        case .recording: "Recording"
        case .finishing: "Finalizing transcript…"
        case .transcribing: "Transcribing on-device…"
        case .summarizing: "Writing notes…"
        case .uploading: "Saving to Google Drive…"
        case .done: "Notes saved"
        case .failed: "Something went wrong"
        }
    }
}

struct LectureMeta: Codable, Equatable {
    var title: String?
    var duration: TimeInterval?
    var docURL: String?
}

struct LectureRecord: Identifiable, Equatable {
    let dir: URL
    let date: Date
    let meta: LectureMeta
    let hasNotes: Bool
    var id: URL { dir }
    var docURL: URL? { meta.docURL.flatMap(URL.init(string:)) }
}

enum Tab: Hashable { case record, transcript, history }

/// Kept separate from AppState so the ~20 Hz level updates only redraw the meter, not the whole popover.
@MainActor
final class LevelMeter: ObservableObject {
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 90)

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append((levels.last ?? 0) * 0.55 + level * 0.45)
        levels = next
    }

    func reset() { levels = Array(repeating: 0, count: levels.count) }

    func set(_ values: [Float]) { levels = values }
}

/// Separate from AppState so transcript updates (several per second) only redraw the transcript.
@MainActor
final class LiveTranscript: ObservableObject {
    @Published private(set) var chunks: [String] = []
    @Published private(set) var volatile: [Int: String] = [:]
    private(set) var finalWords = 0

    var text: String { chunks.joined(separator: " ") }
    var isEmpty: Bool { chunks.isEmpty && volatile.isEmpty }
    var wordCount: Int { finalWords + volatile.values.reduce(0) { $0 + Self.words(in: $1) } }

    func setVolatile(_ text: String, source: Int) { volatile[source] = text }

    func appendFinal(_ text: String, source: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(trimmed)
            finalWords += Self.words(in: trimmed)
        }
        volatile[source] = nil
    }

    func reset() {
        chunks = []
        volatile = [:]
        finalWords = 0
    }

    private static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: Phase = .idle {
        didSet { if confirmingQuit && !isRecording && !phase.isBusy { confirmingQuit = false } }
    }
    @Published var elapsed: TimeInterval = 0
    @Published var lectureTitle = ""
    @Published var context = "" {
        didSet { scheduleTermsUpdate() }
    }
    @Published var tab: Tab = .record
    @Published var showSettings = false
    @Published var settingsTab: SettingsTab = .audio
    let meter = LevelMeter()
    let live = LiveTranscript()
    @Published var history: [LectureRecord] = []

    private var recorder: Recorder?
    private var liveTranscribers: [LiveTranscriber] = []
    private var termsTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt = Date()
    private(set) var sessionDir: URL?
    private var isRegenerating = false
    private var liveIncomplete = false
    private var processTask: Task<Void, Never>?
    @Published var uploadError: String?
    private var audioURL: URL?

    static let rootDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LectureNotes/Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    var isRecording: Bool { phase == .recording }

    /// Comma/newline-separated hints like "merge sort, divide and conquer" become speech-recognition vocabulary.
    var terms: [String] { Self.terms(from: context) }

    static func terms(from context: String) -> [String] {
        context.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 60 }
    }

    private func scheduleTermsUpdate() {
        guard isRecording else { return }
        termsTask?.cancel()
        termsTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            for live in liveTranscribers { await live.updateTerms(terms) }
        }
    }

    var elapsedString: String { Self.format(elapsed) }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    var transcriptText: String { live.text }

    func toggleRecording() {
        if isRecording {
            stop()
        } else if !phase.isBusy {
            start()
        }
    }

    // MARK: Recording

    private func start() {
        let dir = Self.rootDir.appending(path: Self.folderFormat.string(from: Date()))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir
        audioURL = nil
        live.reset()
        meter.reset()
        phase = .preparing

        let prefs = Prefs.shared
        let mic = makeLive(source: 0)
        let system = prefs.audioSource == .micAndSystem ? makeLive(source: 1) : nil
        let recorder = Recorder()
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.pushLevel(level) }
        }
        recorder.onFailure = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.stop()
            }
        }
        self.recorder = recorder
        liveTranscribers = [mic] + (system.map { [$0] } ?? [])
        let terms = self.terms

        liveIncomplete = true

        // Audio capture starts first so nothing is lost while the speech model loads (it can download
        // on first use). If live transcription starts late or fails, the transcript is made from the
        // audio file after Stop instead.
        Task {
            do {
                guard await LiveTranscriber.isSupported(localeID: prefs.localeID) else {
                    throw TranscriberError.unsupportedLocale(prefs.localeID)
                }
                try await recorder.start(in: dir, mic: mic, system: system)
            } catch {
                await mic.finish()
                await system?.finish()
                self.recorder = nil
                liveTranscribers = []
                sessionDir = nil
                try? FileManager.default.removeItem(at: dir)
                phase = .failed(error.localizedDescription)
                return
            }
            startedAt = Date()
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in self.elapsed = Date().timeIntervalSince(self.startedAt) }
            }
            phase = .recording

            let began = Date()
            do {
                try await mic.start(localeID: prefs.localeID, terms: terms)
                try await system?.start(localeID: prefs.localeID, terms: terms)
                if isRecording && Date().timeIntervalSince(began) < LiveTranscriber.maxPendingSeconds - 2 { liveIncomplete = false }
            } catch {}
        }
    }

    private func makeLive(source: Int) -> LiveTranscriber {
        LiveTranscriber(
            onVolatile: { [weak self] text in
                Task { @MainActor in self?.live.setVolatile(text, source: source) }
            },
            onFinal: { [weak self] text in
                Task { @MainActor in
                    self?.live.appendFinal(text, source: source)
                }
            }
        )
    }

    private func pushLevel(_ level: Float) {
        guard isRecording else { return }
        meter.push(level)
    }

    private func stop() {
        phase = .finishing
        processTask = Task {
            do {
                try await saveRecording()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            await process()
        }
    }

    /// Stops capture and writes audio, transcript, and duration to disk.
    private func saveRecording() async throws {
        timer?.invalidate()
        timer = nil
        phase = .finishing
        isRegenerating = false
        var stopError: Error?
        do {
            audioURL = try await recorder?.stop()
        } catch {
            stopError = error
        }
        recorder = nil
        liveTranscribers = []
        // Let the last final results hop to the main actor.
        try? await Task.sleep(for: .milliseconds(200))
        if let dir = sessionDir {
            if !transcriptText.isEmpty && !liveIncomplete {
                try? transcriptText.write(to: dir.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)
            }
            updateMeta(in: dir) { $0.duration = self.elapsed }
            if audioURL == nil { audioURL = dir.appending(path: "mic.m4a") }
        }
        if let stopError { throw stopError }
    }

    // MARK: Quit

    @Published var confirmingQuit = false

    /// Quit right away when idle; otherwise ask first so a lecture isn't lost.
    func requestQuit() {
        if isRecording || phase.isBusy {
            withAnimation(.snappy(duration: 0.2)) { confirmingQuit = true }
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Used when macOS asks the app to quit (logout, restart): save first, then let it go.
    func saveIfRecording() async {
        if isRecording {
            try? await saveRecording()
            phase = .idle
        }
        await waitWhileFinishing()
    }

    /// A recording that's mid-save gets a few seconds to land on disk before the app exits.
    private func waitWhileFinishing() async {
        for _ in 0..<300 where phase == .finishing {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Saves the in-progress recording (notes can be made later from History), then quits.
    func saveAndQuit() {
        Task {
            await saveIfRecording()
            NSApp.terminate(nil)
        }
    }

    /// Re-runs a past lecture. With `retranscribe`, the audio is transcribed again
    /// using the current "Topic & key terms", so the hints apply after the fact.
    func regenerate(_ record: LectureRecord, retranscribe: Bool) {
        guard !isRecording, !phase.isBusy else { return }
        let fm = FileManager.default
        let mixed = record.dir.appending(path: "lecture.m4a")
        audioURL = fm.fileExists(atPath: mixed.path) ? mixed : record.dir.appending(path: "mic.m4a")
        sessionDir = record.dir
        isRegenerating = true
        tab = .record
        phase = retranscribe ? .transcribing : .summarizing
        processTask = Task { await process(forceTranscribe: retranscribe) }
    }

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        withAnimation(.snappy(duration: 0.25)) { showSettings = true }
    }

    var canRetry: Bool { audioURL != nil }

    func retry() {
        guard !phase.isBusy else { return }
        guard canRetry else { phase = .idle; return }
        phase = .summarizing
        processTask = Task { await process() }
    }

    var canCancel: Bool { phase == .transcribing || phase == .summarizing }

    /// Stops making notes (e.g. the AI is slow and the next class is starting). The recording stays saved.
    func cancelProcessing() {
        guard canCancel else { return }
        processTask?.cancel()
        processTask = nil
        phase = .failed("Stopped. Your recording is saved, so hit Retry whenever you want notes.")
    }

    private func process(forceTranscribe: Bool = false) async {
        guard let audioURL, let dir = sessionDir else { phase = .idle; return }
        let prefs = Prefs.shared
        let regenerating = isRegenerating
        let savedContext = (try? String(contentsOf: dir.appending(path: "context.txt"), encoding: .utf8)) ?? ""
        let hints = (regenerating && context.isEmpty ? savedContext : context).trimmingCharacters(in: .whitespacesAndNewlines)
        let hintTerms = regenerating && context.isEmpty ? Self.terms(from: savedContext) : terms
        do {
            let transcriptURL = dir.appending(path: "transcript.txt")
            let transcript: String
            if !forceTranscribe, let saved = try? String(contentsOf: transcriptURL, encoding: .utf8), !saved.isEmpty {
                transcript = saved
            } else {
                phase = .transcribing
                transcript = try await Transcriber.transcribe(audioURL, localeID: prefs.localeID, terms: hintTerms)
                guard !Task.isCancelled else { return }
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }

            phase = .summarizing
            let model = prefs.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = prefs.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = LLMConfig(provider: prefs.provider,
                                   model: model.isEmpty ? prefs.provider.defaultModel : model,
                                   baseURL: baseURL.isEmpty ? prefs.provider.defaultBaseURL : baseURL,
                                   apiKey: prefs.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                   stylePrompt: prefs.stylePrompt)
            if !hints.isEmpty { try? hints.write(to: dir.appending(path: "context.txt"), atomically: true, encoding: .utf8) }
            let notes = try await Summarizer.summarize(transcript, context: hints, config: config)
            guard !Task.isCancelled else { return }
            try notes.write(to: dir.appending(path: "notes.md"), atomically: true, encoding: .utf8)
            let title = docTitle(notes: notes, dir: dir, regenerating: regenerating)
            let html = Markdown.html(notes, title: title)
            try Markdown.html(notes, title: title, styled: true).write(to: dir.appending(path: "notes.html"), atomically: true, encoding: .utf8)
            updateMeta(in: dir) { $0.title = title }

            var docURL: URL?
            uploadError = nil
            if Google.shared.email != nil {
                phase = .uploading
                do {
                    let url = try await Google.shared.createDoc(title: title, html: html, folderID: prefs.folderID)
                    updateMeta(in: dir) { $0.docURL = url.absoluteString }
                    docURL = url
                } catch {
                    uploadError = "Couldn't upload to Google Drive (\(error.localizedDescription)). Your notes are saved here."
                }
            }

            phase = .done(docURL)
            if !regenerating {
                lectureTitle = ""
                context = ""
            }
            loadHistory()
            if prefs.openDocWhenDone {
                if let docURL { NSWorkspace.shared.open(docURL) }
            }
            try? FileManager.default.removeItem(at: dir.appending(path: "error.txt"))
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error.localizedDescription)
            let line = "\(Date().formatted(.iso8601)) [\(prefs.provider.rawValue) \(prefs.model)] \(error.localizedDescription) | \(error)\n"
            try? line.write(to: dir.appending(path: "error.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func docTitle(notes: String, dir: URL, regenerating: Bool) -> String {
        let recorded = Self.folderFormat.date(from: dir.lastPathComponent) ?? Date()
        let date = recorded.formatted(.dateTime.month(.abbreviated).day().year())
        let previous = regenerating ? existingTitle(in: dir) : nil
        let name = previous ?? lectureTitle.trimmingCharacters(in: .whitespaces)
        let title = name.isEmpty ? (Markdown.title(of: notes) ?? "Lecture Notes") : name
        return "\(date) — \(title)"
    }

    private func existingTitle(in dir: URL) -> String? {
        let meta = try? JSONDecoder().decode(LectureMeta.self, from: Data(contentsOf: dir.appending(path: "meta.json")))
        return meta?.title?.components(separatedBy: " — ").last
    }

    // MARK: History

    private func updateMeta(in dir: URL, _ change: (inout LectureMeta) -> Void) {
        let url = dir.appending(path: "meta.json")
        var meta = (try? JSONDecoder().decode(LectureMeta.self, from: Data(contentsOf: url))) ?? LectureMeta()
        change(&meta)
        try? JSONEncoder().encode(meta).write(to: url)
    }

    func loadHistory() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.rootDir, includingPropertiesForKeys: nil)) ?? []
        let records = dirs.compactMap { dir -> LectureRecord? in
            guard let date = Self.folderFormat.date(from: dir.lastPathComponent) else { return nil }
            let meta = (try? JSONDecoder().decode(LectureMeta.self, from: Data(contentsOf: dir.appending(path: "meta.json")))) ?? LectureMeta()
            let hasNotes = FileManager.default.fileExists(atPath: dir.appending(path: "notes.md").path)
            return LectureRecord(dir: dir, date: date, meta: meta, hasNotes: hasNotes)
        }
        .sorted { $0.date > $1.date }
        if records != history { history = records }
    }

    /// Copies the notes as rich text, so pasting into Google Docs, Notion, Notes, etc. keeps the formatting.
    func copyNotes(_ dir: URL? = nil) {
        guard let dir = dir ?? sessionDir,
              let notes = try? String(contentsOf: dir.appending(path: "notes.md"), encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Markdown.html(notes), forType: .html)
        pasteboard.setString(notes, forType: .string)
    }

    func openNotes(_ dir: URL? = nil) {
        guard let dir = dir ?? sessionDir else { return }
        let html = dir.appending(path: "notes.html")
        if !FileManager.default.fileExists(atPath: html.path),
           let notes = try? String(contentsOf: dir.appending(path: "notes.md"), encoding: .utf8) {
            try? Markdown.html(notes, styled: true).write(to: html, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(html)
    }

    func showFiles(_ dir: URL? = nil) {
        NSWorkspace.shared.open(dir ?? sessionDir ?? Self.rootDir)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
