import AppKit
import SwiftUI
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

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
    /// The person named it, so making notes again keeps their name instead of the AI's.
    var named: Bool?
    var important: [String]?
    /// Which engine made transcript.txt: "whisper", "apple" (from the file), or "live".
    var transcriber: String?
    /// Making notes was interrupted by a new recording; offer to finish them later.
    var notesPending: Bool?
    var duration: TimeInterval?
    var docURL: String?
}

struct SlideDeck: Equatable, Identifiable {
    let name: String
    let text: String
    var id: String { name }
}

struct LectureRecord: Identifiable, Equatable {
    let dir: URL
    let date: Date
    let meta: LectureMeta
    let hasNotes: Bool
    var id: URL { dir }
    var docURL: URL? { meta.docURL.flatMap(URL.init(string:)) }
    /// Saved titles look like "Nov 9, 2026 — Divide and Conquer"; this is the part after the date.
    var name: String { meta.title?.components(separatedBy: " — ").last ?? "Untitled lecture" }
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
    @Published var slides: [SlideDeck] = [] {
        didSet {
            slideTerms = Self.slideTerms(from: slidesText)
            scheduleTermsUpdate()
        }
    }
    @Published var slidesError: String?
    private var slideTerms: [String] = []
    @Published var tab: Tab = .record
    @Published var showSettings = false
    @Published var settingsTab: SettingsTab = .audio
    let meter = LevelMeter()
    let live = LiveTranscript()
    @Published var history: [LectureRecord] = []
    @Published var openLecture: URL?
    @Published var renameRequested = false

    private var recorder: Recorder?
    private var liveTranscribers: [LiveTranscriber] = []
    private var termsTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt = Date()
    private(set) var sessionDir: URL?
    private var liveIncomplete = false
    /// The speech service died mid-recording; the audio is fine and gets transcribed in full after Stop.
    @Published var liveInterrupted = false
    /// 0–1 while Whisper transcribes, for the status row.
    @Published var transcribeProgress: Double?
    /// Set when Whisper failed and the notes fell back to Apple's transcript.
    @Published var transcriptNotice: String?
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

    /// Jargon and titles from the attached slides become speech-recognition vocabulary.
    var terms: [String] { slideTerms }

    var slidesText: String { slides.map(\.text).joined(separator: "\n\n") }

    static func slideTerms(from text: String) -> [String] {
        text.isEmpty ? [] : Slides.terms(from: text)
    }

    /// Terms typed in older versions go first, so they survive if the recognizer caps how many it uses.
    static func merge(_ typed: [String], _ fromSlides: [String]) -> [String] {
        var seen = Set<String>()
        return (typed + fromSlides).filter { seen.insert($0.lowercased()).inserted }
    }

    func addSlides(_ urls: [URL]) {
        let supported = urls.filter { Slides.fileTypes.contains($0.pathExtension.lowercased()) }
        guard !supported.isEmpty else {
            slidesError = "That isn't a slide file. Use a PDF or PowerPoint."
            return
        }
        let (decks, error) = Self.read(supported, skipping: slides.map(\.name))
        slides += decks
        slidesError = error
    }

    private static func read(_ urls: [URL], skipping names: [String] = []) -> ([SlideDeck], String?) {
        var decks: [SlideDeck] = []
        var lastError: String?
        for url in urls where Slides.fileTypes.contains(url.pathExtension.lowercased()) {
            let name = url.lastPathComponent
            guard !names.contains(name), !decks.contains(where: { $0.name == name }) else { continue }
            do {
                decks.append(SlideDeck(name: name, text: try Slides.text(from: url)))
            } catch {
                lastError = error.localizedDescription
            }
        }
        return (decks, lastError)
    }

    /// The popover closes while the panel is up; attached slides stay in state for when it reopens.
    func chooseSlides() {
        addSlides(Self.pickSlideFiles())
    }

    private static func pickSlideFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Slides.fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose the lecture slides"
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Fixes a past lecture: attach its slides, then re-transcribe and re-write the notes with them.
    func addSlidesAndRetranscribe(_ record: LectureRecord) {
        guard !isRecording, !phase.isBusy else { return }
        let (decks, error) = Self.read(Self.pickSlideFiles())
        guard !decks.isEmpty else {
            if let error {
                tab = .record
                slidesError = error
            }
            return
        }
        let text = decks.map(\.text).joined(separator: "\n\n")
        try? text.write(to: record.dir.appending(path: "slides.txt"), atomically: true, encoding: .utf8)
        regenerate(record, retranscribe: true)
    }

    /// Key terms typed into older versions of the app (saved as context.txt).
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
        } else if canStartRecording {
            if phase.isBusy { pauseNotesForRecording() }
            start()
        }
    }

    /// Back-to-back classes: a new recording can start while the last one's notes are still being made.
    var canStartRecording: Bool { !phase.isBusy || phase == .transcribing || phase == .summarizing }

    private func pauseNotesForRecording() {
        if let dir = sessionDir { updateMeta(in: dir) { $0.notesPending = true } }
        processTask?.cancel()
        processTask = nil
        transcribeProgress = nil
    }

    /// The most recent lecture whose notes were paused by a new recording.
    var pausedLecture: LectureRecord? {
        history.first { $0.meta.notesPending == true && !$0.hasNotes && $0.dir != sessionDir }
    }

    // MARK: Recording

    private func start() {
        let dir = Self.rootDir.appending(path: Self.folderFormat.string(from: Date()))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir
        if !slides.isEmpty { try? slidesText.write(to: dir.appending(path: "slides.txt"), atomically: true, encoding: .utf8) }
        audioURL = nil
        live.reset()
        meter.reset()
        liveInterrupted = false
        transcriptNotice = nil
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
            },
            onFailure: { [weak self] in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.liveIncomplete = true
                    self.liveInterrupted = true
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
            // Slides and a typed name belong to this lecture now, so the next class starts clean even
            // while these notes are still being made.
            if slides.isEmpty {
                try? FileManager.default.removeItem(at: dir.appending(path: "slides.txt"))
            } else {
                try? slidesText.write(to: dir.appending(path: "slides.txt"), atomically: true, encoding: .utf8)
            }
            let typedName = lectureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let recorded = Self.folderFormat.date(from: dir.lastPathComponent) ?? Date()
            updateMeta(in: dir) {
                $0.duration = self.elapsed
                if !typedName.isEmpty {
                    $0.title = Self.fullTitle(name: typedName, date: recorded)
                    $0.named = true
                }
            }
            slides = []
            lectureTitle = ""
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
    /// using the lecture's saved slides.
    func regenerate(_ record: LectureRecord, retranscribe: Bool) {
        guard !isRecording, !phase.isBusy else { return }
        let fm = FileManager.default
        let mixed = record.dir.appending(path: "lecture.m4a")
        audioURL = fm.fileExists(atPath: mixed.path) ? mixed : record.dir.appending(path: "mic.m4a")
        sessionDir = record.dir
        if openLecture != record.dir { tab = .record }
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
        let savedContext = (try? String(contentsOf: dir.appending(path: "context.txt"), encoding: .utf8)) ?? ""
        let hints = savedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let slideText = (try? String(contentsOf: dir.appending(path: "slides.txt"), encoding: .utf8)) ?? ""
        let hintTerms = Self.merge(Self.terms(from: savedContext), Self.slideTerms(from: slideText))
        do {
            let transcript = try await makeTranscript(audioURL: audioURL, dir: dir, terms: hintTerms, force: forceTranscribe)
            guard !Task.isCancelled else { return }

            phase = .summarizing
            let model = prefs.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = prefs.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = LLMConfig(provider: prefs.provider,
                                   model: model.isEmpty ? prefs.provider.defaultModel : model,
                                   baseURL: baseURL.isEmpty ? prefs.provider.defaultBaseURL : baseURL,
                                   apiKey: prefs.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                   stylePrompt: prefs.stylePrompt)
            let recorded = Self.folderFormat.date(from: dir.lastPathComponent) ?? Date()
            let summary = try await Summarizer.summarize(transcript, context: hints, slides: slideText, date: recorded, config: config)
            guard !Task.isCancelled else { return }
            let notes = summary.notes
            try notes.write(to: dir.appending(path: "notes.md"), atomically: true, encoding: .utf8)
            let title = docTitle(summary: summary, dir: dir)
            let html = Markdown.html(notes, title: title)
            try Markdown.html(notes, title: title, styled: true).write(to: dir.appending(path: "notes.html"), atomically: true, encoding: .utf8)
            updateMeta(in: dir) {
                $0.title = title
                $0.important = summary.important
            }

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
            loadHistory()
            if prefs.openDocWhenDone {
                if let docURL { NSWorkspace.shared.open(docURL) }
            }
            try? FileManager.default.removeItem(at: dir.appending(path: "error.txt"))
            updateMeta(in: dir) { $0.notesPending = nil }
            loadHistory()
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error.localizedDescription)
            let line = "\(Date().formatted(.iso8601)) [\(prefs.provider.rawValue) \(prefs.model)] \(error.localizedDescription) | \(error)\n"
            try? line.write(to: dir.appending(path: "error.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Whisper (when downloaded and on) gives the best transcript, so it replaces the live one. If it fails,
    /// fall back to the live transcript, then to Apple's file transcription, so there are always notes.
    private func makeTranscript(audioURL: URL, dir: URL, terms: [String], force: Bool) async throws -> String {
        let prefs = Prefs.shared
        let transcriptURL = dir.appending(path: "transcript.txt")
        let saved = (try? String(contentsOf: transcriptURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let savedBy = readMeta(in: dir).transcriber ?? (saved.isEmpty ? nil : "live")
        let useWhisper = prefs.highAccuracy && WhisperFiles.isInstalled
        transcriptNotice = nil

        if !force && !saved.isEmpty && (savedBy == "whisper" || !useWhisper) { return saved }

        func save(_ text: String, by engine: String) throws -> String {
            try text.write(to: transcriptURL, atomically: true, encoding: .utf8)
            updateMeta(in: dir) { $0.transcriber = engine }
            return text
        }

        phase = .transcribing
        if useWhisper {
            if savedBy == "live" {
                try? saved.write(to: dir.appending(path: "transcript-live.txt"), atomically: true, encoding: .utf8)
            }
            transcribeProgress = 0
            defer { transcribeProgress = nil }
            let language = Locale(identifier: prefs.localeID).language.languageCode?.identifier ?? "en"
            do {
                let text = try await WhisperTranscriber.transcribe(audioURL, languageCode: language) { progress in
                    Task { @MainActor in
                        if AppState.shared.transcribeProgress != nil { AppState.shared.transcribeProgress = progress }
                    }
                }
                return try save(text, by: "whisper")
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                transcriptNotice = "High-accuracy transcription failed, so these notes use the standard transcript. \(error.localizedDescription)"
                NSLog("Whisper failed: \(error)")
            }
        }
        if !force && !saved.isEmpty { return saved }
        let text = try await Transcriber.transcribe(audioURL, localeID: prefs.localeID, terms: terms)
        return try save(text, by: "apple")
    }

    var statusLabel: String {
        if phase == .transcribing, let progress = transcribeProgress {
            return "Transcribing (high accuracy) \(Int(progress * 100))%"
        }
        return phase.label
    }

    /// A name the person gave wins; otherwise the AI's short name, then the notes' heading.
    private func docTitle(summary: LectureSummary, dir: URL) -> String {
        let recorded = Self.folderFormat.date(from: dir.lastPathComponent) ?? Date()
        let kept = readMeta(in: dir).named == true ? existingTitle(in: dir) : nil
        let name = kept ?? summary.name ?? Markdown.title(of: summary.notes) ?? "Lecture Notes"
        return Self.fullTitle(name: name, date: recorded)
    }

    private func readMeta(in dir: URL) -> LectureMeta {
        (try? JSONDecoder().decode(LectureMeta.self, from: Data(contentsOf: dir.appending(path: "meta.json")))) ?? LectureMeta()
    }

    private static func fullTitle(name: String, date: Date) -> String {
        "\(date.formatted(.dateTime.month(.abbreviated).day().year())) — \(name)"
    }

    /// Renames a past lecture everywhere it shows up: History, the saved notes page, and its Google Doc.
    func rename(_ record: LectureRecord, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != (existingTitle(in: record.dir) ?? record.name) else { return }
        let title = Self.fullTitle(name: name, date: record.date)
        updateMeta(in: record.dir) {
            $0.title = title
            $0.named = true
        }
        if let notes = try? String(contentsOf: record.dir.appending(path: "notes.md"), encoding: .utf8) {
            try? Markdown.html(notes, title: title, styled: true).write(to: record.dir.appending(path: "notes.html"), atomically: true, encoding: .utf8)
        }
        loadHistory()
        if let docURL = record.docURL {
            Task { try? await Google.shared.renameDoc(docURL, to: title) }
        }
    }

    func isProcessing(_ record: LectureRecord) -> Bool {
        sessionDir == record.dir && (phase.isBusy || isRecording)
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
