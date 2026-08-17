// SPDX-License-Identifier: Apache-2.0
import AppKit

/// A small, transient on-screen indicator (like the macOS volume HUD) shown
/// when the global hotkey toggles keep-awake — the app has no focused window,
/// so this confirms the action without stealing focus or needing notification
/// permission.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private init() {}

    func show(symbol: String, text: String) {
        let panel = ensurePanel()
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .semibold))
        imageView.contentTintColor = .labelColor
        label.stringValue = text

        reposition(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let size = NSSize(width: 230, height: 64)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.maskImage = HUD.roundedMask(radius: 16)
        blur.autoresizingMask = [.width, .height]

        imageView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 32),
            imageView.heightAnchor.constraint(equalToConstant: 32),
        ])

        p.contentView = blur
        panel = p
        return p
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2,
                                     y: screen.frame.minY + 140))
    }

    /// A resizable rounded-rectangle mask for the vibrancy view. Using
    /// `NSVisualEffectView.maskImage` (rather than a CALayer `cornerRadius`)
    /// clips the backdrop cleanly and lets the window shadow follow the rounded
    /// shape, avoiding the square, light-colored corners AppKit leaves behind
    /// when the effect view's own layer is corner-rounded directly.
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

    /// Debug: render the live HUD panel content (masked vibrancy view + its
    /// contents) composited over a saturated background and write it to `path`.
    /// The saturated backdrop makes any un-clipped corner/edge fill obvious.
    /// Mirrors `--render-prefs` so the HUD shape can be verified without a
    /// window server screenshot. Vibrancy blur can't be captured offscreen, but
    /// the mask clipping (the actual bug surface) is.
    static func renderForTest(to path: String) {
        let hud = HUD.shared
        hud.imageView.image = NSImage(systemSymbolName: "cup.and.saucer.fill",
                                      accessibilityDescription: "Keep Awake On")?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .semibold))
        hud.imageView.contentTintColor = .labelColor
        hud.label.stringValue = "Keep Awake On"
        let panel = hud.ensurePanel()
        guard let content = panel.contentView else { print("render failed"); return }
        content.layoutSubtreeIfNeeded()

        // cacheDisplay draws the view hierarchy through draw(_:), rendering the
        // vibrancy material's fallback fill clipped by the maskImage — so the
        // rounded shape and its corner/edge clipping are captured offscreen.
        let viewRep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: viewRep)

        let inset: CGFloat = 24
        let full = NSRect(x: 0, y: 0,
                          width: content.bounds.width + inset * 2,
                          height: content.bounds.height + inset * 2)
        let image = NSImage(size: full.size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        full.fill()
        viewRep.draw(in: NSRect(x: inset, y: inset,
                                width: content.bounds.width, height: content.bounds.height))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
