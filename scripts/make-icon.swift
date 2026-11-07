import AppKit

// Renders Resources/AppIcon.icns: white waveform on an indigo→violet squircle.
func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    let inset = 100 * s
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.33, blue: 0.96, alpha: 1),
                        NSColor(red: 0.62, green: 0.30, blue: 0.93, alpha: 1)])!
        .draw(in: squircle, angle: -60)

    NSColor.white.setFill()
    let page = tile

    let heights: [CGFloat] = [0.3, 0.58, 0.9, 0.62, 1.0, 0.7, 0.44, 0.26]
    let barWidth = 44 * s, gap = 32 * s
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = page.midX - total / 2
    for h in heights {
        let height = h * 470 * s
        let bar = NSRect(x: x, y: page.midY - height / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
