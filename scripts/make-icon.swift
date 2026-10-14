// Renders the default app icon into an .iconset folder. Usage: swift make-icon.swift <output.iconset>
// build-app.sh uses this only when Resources/AppIcon.icns doesn't exist.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let body = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.18, blue: 0.26, alpha: 1), NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)])!
        .draw(in: body, angle: -90)

    // Film strip with sprocket holes and a play triangle.
    let strip = NSRect(x: 210 * s, y: 330 * s, width: 604 * s, height: 364 * s)
    NSColor(red: 0.98, green: 0.62, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(roundedRect: strip, xRadius: 44 * s, yRadius: 44 * s).fill()
    NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1).setFill()
    for i in 0..<7 {
        let x = 246 * s + CGFloat(i) * 80 * s
        NSBezierPath(roundedRect: NSRect(x: x, y: 638 * s, width: 44 * s, height: 30 * s), xRadius: 8 * s, yRadius: 8 * s).fill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 356 * s, width: 44 * s, height: 30 * s), xRadius: 8 * s, yRadius: 8 * s).fill()
    }
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: 452 * s, y: 432 * s))
    tri.line(to: NSPoint(x: 452 * s, y: 592 * s))
    tri.line(to: NSPoint(x: 588 * s, y: 512 * s))
    tri.close()
    tri.fill()

    let label = NSAttributedString(string: "MP4", attributes: [
        .font: NSFont.systemFont(ofSize: 150 * s, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: 6 * s,
    ])
    let ls = label.size()
    label.draw(at: NSPoint(x: (1024 * s - ls.width) / 2, y: 150 * s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
