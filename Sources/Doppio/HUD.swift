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
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
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
}
