import AppKit
import SwiftUI

/// Borderless, floating, non-activating panel. It can become key (to receive Escape, arrows and
/// modifier changes) without activating PinTab, so the origin app stays active.
final class SwitcherPanel: NSPanel {
    let hostingView: NSHostingView<SwitcherRootView>
    /// Glass behind the icon row (switching) or the whole editor (managing). Content outside it,
    /// such as the floating name pill, sits on the transparent window.
    private let bubble = SwitcherPanel.makeBubble()

    init(model: SwitcherViewModel) {
        hostingView = NSHostingView(rootView: SwitcherRootView(model: model))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        // Show on whichever Space is current, including over full-screen apps; never in Exposé or
        // window cycling.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        title = "PinTab"
        setAccessibilitySubrole(.floatingWindow)

        // Intrinsic size lets fittingSize report the SwiftUI content size; with [] it reports zero.
        hostingView.sizingOptions = [.intrinsicContentSize]
        let container = NSView()
        container.addSubview(bubble)
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        contentView = container
    }

    /// Positions the glass, in window content coordinates (origin at the bottom left).
    func setBubbleFrame(_ frame: NSRect) {
        bubble.frame = frame
        hostingView.frame = contentView?.bounds ?? .zero
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Liquid Glass on macOS 26; a behind-window blur material on earlier versions. Both honour
    /// Reduce Transparency automatically.
    private static func makeBubble() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Metrics.cornerRadius
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .popover // follows light and dark appearance
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: Metrics.cornerRadius)
        return effect
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
