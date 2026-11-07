import AppKit
import SwiftUI

/// Menu bar icon while notes are being made: each dot smoothly hops in turn, then a short rest.
@MainActor
final class BusyAnimator: ObservableObject {
    static let frameCount = 40
    static let frames: [NSImage] = (0..<frameCount).map(makeFrame)

    @Published private(set) var frame = 0
    private var timer: Timer?

    func setRunning(_ running: Bool) {
        if running, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.frame = (self.frame + 1) % Self.frameCount
                }
            }
        } else if !running {
            timer?.invalidate()
            timer = nil
            frame = 0
        }
    }

    private static func makeFrame(_ index: Int) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5))
            ring.lineWidth = 1.5
            ring.stroke()

            let dot: CGFloat = 2.6
            let gap: CGFloat = 1.6
            let startX = (size.width - (3 * dot + 2 * gap)) / 2
            for i in 0..<3 {
                let lift = 2.2 * hop(Double(index) / Double(frameCount) - Double(i) * 0.15)
                let rect = NSRect(x: startX + CGFloat(i) * (dot + gap), y: (size.height - dot) / 2 + lift,
                                  width: dot, height: dot)
                NSBezierPath(ovalIn: rect).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// One smooth up-and-down over the first 30% of the cycle, resting the rest of the time.
    private static func hop(_ t: Double) -> CGFloat {
        let p = (t.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) / 0.3
        return p < 1 ? CGFloat(sin(p * .pi)) : 0
    }
}

struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @StateObject private var animator = BusyAnimator()

    var body: some View {
        Group {
            if state.phase == .recording {
                Label(state.elapsedString, systemImage: "record.circle.fill")
                    .labelStyle(.titleAndIcon)
            } else if state.phase.isBusy {
                Image(nsImage: BusyAnimator.frames[animator.frame])
            } else {
                Image(systemName: "waveform")
            }
        }
        .onAppear { animator.setRunning(state.phase.isBusy) }
        .onChange(of: state.phase.isBusy) { _, busy in animator.setRunning(busy) }
    }
}
