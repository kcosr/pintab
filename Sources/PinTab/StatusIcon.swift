import AppKit

/// The menu-bar glyph: a small switcher panel with three app tiles, the middle one selected.
/// Drawn as vector paths into a template image, so macOS tints it for light and dark menu bars.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let panel = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 3.7, width: 15.6, height: 10.6), xRadius: 3.2, yRadius: 3.2)
            panel.lineWidth = 1.4
            panel.stroke()
            // Three tiles; the selected middle one is solid, the others half strength.
            for (index, x) in [3.6, 7.5, 11.4].enumerated() {
                NSColor.black.withAlphaComponent(index == 1 ? 1 : 0.45).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 7.05, width: 3.0, height: 3.9), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PinTab"
        return image
    }()
}
