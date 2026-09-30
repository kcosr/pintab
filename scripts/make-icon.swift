// Renders Support/AppIcon.icns: the menu-bar glyph (a switcher panel with three tiles) in white on a blue rounded square.
// Usage: swift scripts/make-icon.swift  (run from the repository root; needs iconutil)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // macOS icon grid: the shape occupies ~80% of the canvas.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.47, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.78, alpha: 1))!.draw(in: shape, angle: -90)

    // The menu-bar glyph, scaled up: a switcher panel with three tiles, the middle one selected.
    // Glyph coordinates are in an 18-point box; map that box onto the middle of the icon.
    let unit = rect.width * 0.72 / 18
    let origin = NSPoint(x: rect.midX - 9 * unit, y: rect.midY - 9 * unit)
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: origin.x + x * unit, y: origin.y + y * unit, width: w * unit, height: h * unit)
    }
    let panelRect = box(1.2, 3.7, 15.6, 10.6)
    let panel = NSBezierPath(roundedRect: panelRect, xRadius: 3.2 * unit, yRadius: 3.2 * unit)
    NSColor.white.withAlphaComponent(0.14).setFill()
    panel.fill()
    NSColor.white.setStroke()
    panel.lineWidth = 1.4 * unit
    panel.stroke()
    for (index, x) in [3.6, 7.5, 11.4].enumerated() {
        NSColor.white.withAlphaComponent(index == 1 ? 1 : 0.5).setFill()
        let tile = box(CGFloat(x), 7.05, 3.0, 3.9)
        NSBezierPath(roundedRect: tile, xRadius: 1 * unit, yRadius: 1 * unit).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let output = root.appendingPathComponent("Support/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
