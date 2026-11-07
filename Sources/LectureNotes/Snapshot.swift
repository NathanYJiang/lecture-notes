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
        render("done") { state.phase = .done(nil); state.meter.reset(); state.elapsed = 0 }
        render("failed") { state.phase = .failed(SummarizerError.http(503, "This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later.").localizedDescription) }
        render("failed-raw") { state.phase = .failed(SummarizerError.http(400, "This model models/gemini-2.5-flash is no longer available to new users. Please update your code to use models/gemini-3.8-flash for the latest features and improvements. We recommend you to use the Interactions API (https://aistudio.google.com/docs/get-started).").localizedDescription) }
        render("transcript") { state.tab = .transcript }
        render("history") { state.tab = .history; state.loadHistory() }
        render("quit") { state.showSettings = false; state.phase = .recording; state.confirmingQuit = true }
        render("settings") { state.confirmingQuit = false; state.showSettings = true }
        exit(0)
    }
}
#endif
