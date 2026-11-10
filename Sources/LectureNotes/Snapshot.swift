#if DEBUG
import SwiftUI

/// `LectureNotes --snapshot <dir>` renders each pane to PNG for design review (debug builds only).
@MainActor
enum Snapshot {
    /// `LectureNotes --demo-busy` fakes the "making notes" state for 20s to check the menu bar animation.
    static func demoBusyIfRequested() {
        guard CommandLine.arguments.contains("--demo-busy") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            AppState.shared.phase = .summarizing
            try? await Task.sleep(for: .seconds(20))
            exit(0)
        }
    }

    /// `LectureNotes --renote <lecture dir> <out.md>` re-runs the AI on a saved transcript with the current
    /// settings and writes the result to <out.md>, without touching the lecture. For tuning the notes prompt.
    static func renoteIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--renote"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let out = URL(fileURLWithPath: args[i + 2])
        Task { @MainActor in
            let prefs = Prefs.shared
            let read = { (file: String) in (try? String(contentsOf: dir.appending(path: file), encoding: .utf8)) ?? "" }
            let config = LLMConfig(provider: prefs.provider, model: prefs.model, baseURL: prefs.baseURL,
                                   apiKey: prefs.apiKey, stylePrompt: prefs.stylePrompt)
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let recorded = format.date(from: dir.lastPathComponent) ?? Date()
            var text: String
            do {
                let s = try await Summarizer.summarize(read("transcript.txt"), context: read("context.txt"),
                                                       slides: read("slides.txt"), date: recorded, config: config)
                text = "NAME: \(s.name ?? "-")\nIMPORTANT:\n" + s.important.map { "- \($0)" }.joined(separator: "\n") + "\n\n---\n\n" + s.notes
            } catch {
                text = "ERROR: \(error.localizedDescription) | \(error)"
            }
            try? text.write(to: out, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let state = AppState()
        state.meter.set((0..<90).map { _ in Float.random(in: 0.1...0.7) })
        state.elapsed = 1724
        state.live.appendFinal("Today we're talking about gradient descent.", source: 0)
        state.live.appendFinal("It minimizes a loss function by stepping along the negative gradient.", source: 0)
        state.live.setVolatile("The learning rate controls", source: 0)

        func render(_ name: String, _ configure: () -> Void) {
            configure()
            let view = PopoverView()
                .environmentObject(state)
                .environmentObject(Prefs.shared)
                .environmentObject(Google.shared)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appending(path: "\(name).png"))
            }
        }
        render("record") { state.phase = .recording }
        render("slides") { state.phase = .idle; state.slides = [SlideDeck(name: "CS180 Lecture 7 - Shortest Paths.pdf", text: "--- Slide 1 ---\nDijkstra's Algorithm")] }
        render("done") { state.slides = []; state.phase = .done(nil); state.meter.reset(); state.elapsed = 0 }
        render("failed") { state.phase = .failed(SummarizerError.http(503, "This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later.").localizedDescription) }
        render("failed-raw") { state.phase = .failed(SummarizerError.http(400, "This model models/gemini-2.5-flash is no longer available to new users. Please update your code to use models/gemini-3.8-flash for the latest features and improvements. We recommend you to use the Interactions API (https://aistudio.google.com/docs/get-started).").localizedDescription) }
        render("transcript") { state.tab = .transcript }
        render("history") { state.tab = .history; state.loadHistory() }
        render("lecture") { state.openLecture = state.history.first(where: \.hasNotes)?.dir }
        render("lecture-transcript") { state.openLecture = state.history.first?.dir }
        render("quit") { state.showSettings = false; state.phase = .recording; state.confirmingQuit = true }
        render("settings") { state.confirmingQuit = false; state.showSettings = true }
        if let dir = state.history.first(where: \.hasNotes)?.dir,
           let notes = try? String(contentsOf: dir.appending(path: "notes.md"), encoding: .utf8) {
            let renderer = ImageRenderer(content: NotesText(markdown: notes).padding(14).frame(width: DS.width - 28)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]).appending(path: "notes.png"))
            }
        }
        exit(0)
    }
}
#endif
