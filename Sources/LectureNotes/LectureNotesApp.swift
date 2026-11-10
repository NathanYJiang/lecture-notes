import SwiftUI

@main
struct LectureNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    init() {
        #if DEBUG
        Snapshot.runIfRequested()
        Snapshot.demoBusyIfRequested()
        Snapshot.renoteIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
                .environmentObject(Prefs.shared)
                .environmentObject(Google.shared)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Menu bar apps have no window, so on first launch say where the app went.
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot") || $0 == "--demo-busy" || $0 == "--renote" }) { return }
        #endif
        let localeID = Prefs.shared.localeID
        Task.detached(priority: .utility) { await LiveTranscriber.preload(localeID: localeID) }
        let key = "didShowWelcome"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: AppState.rootDir.path)) ?? []
        guard existing.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Lecture Notes is in your menu bar"
            alert.informativeText = "Look for the waveform icon at the top right of your screen. Click it to record a lecture.\n\nFirst, add a free Gemini key: click the icon, then Settings → AI."
            alert.addButton(withTitle: "Got it")
            NSApp.activate()
            alert.runModal()
        }
    }

    /// Logout/restart/shutdown while recording or saving: get the lecture onto disk before exiting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        guard state.isRecording || state.phase == .finishing else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.saveIfRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
