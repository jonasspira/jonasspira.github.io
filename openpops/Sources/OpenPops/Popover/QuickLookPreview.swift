import AppKit
import Quartz

/// A panel that never takes keyboard focus, so the popover keeps handling the arrow keys.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Quick Look preview shown next to the popover (Space toggles it).
@MainActor
final class QuickLookPreview: NSObject {
    private var panel: NonKeyPanel?
    private var previewView: QLPreviewView?
    private let titleLabel = NSTextField(labelWithString: "")
    private(set) var url: URL?

    /// Called after "Open" is clicked, so the popover can close.
    var onOpen: (() -> Void)?

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle(_ url: URL, beside frame: NSRect, appearance: NSAppearance?) {
        if isShown && self.url == url {
            close()
        } else {
            show(url, beside: frame, appearance: appearance)
        }
    }

    func show(_ url: URL, beside frame: NSRect, appearance: NSAppearance?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.appearance = appearance
        self.url = url
        titleLabel.stringValue = url.lastPathComponent
        previewView?.previewItem = url as NSURL
        panel.setFrame(placement(beside: frame, size: NSSize(width: 460, height: 500)), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Updates the previewed file while keeping the panel where it is.
    func update(_ url: URL) {
        guard isShown, url != self.url else { return }
        self.url = url
        titleLabel.stringValue = url.lastPathComponent
        previewView?.previewItem = url as NSURL
    }

    func close() {
        guard let panel = panel else { return }
        previewView?.previewItem = nil
        panel.orderOut(nil)
        url = nil
    }

    /// Beside the popover on whichever side has more room, shrinking to fit when needed.
    private func placement(beside frame: NSRect, size: NSSize) -> NSRect {
        let screen = NSScreen.containing(NSPoint(x: frame.midX, y: frame.midY))
        let visible = screen?.visibleFrame ?? frame.insetBy(dx: -600, dy: -600)
        let gap: CGFloat = 8, margin: CGFloat = 6
        let roomRight = visible.maxX - margin - (frame.maxX + gap)
        let roomLeft = (frame.minX - gap) - (visible.minX + margin)
        let onRight = roomRight >= size.width || roomRight >= roomLeft
        let room = onRight ? roomRight : roomLeft
        let w = max(min(size.width, room), min(260, size.width))
        let h = max(min(size.height, visible.height - 2 * margin), 240)
        var x = onRight ? frame.maxX + gap : frame.minX - gap - w
        x = min(max(x, visible.minX + margin), visible.maxX - margin - w)
        let y = min(max(frame.minY, visible.minY + margin), visible.maxY - margin - h)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func makePanel() -> NonKeyPanel {
        let panel = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let r: CGFloat = 14
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        effect.maskImage = mask
        panel.contentView = effect

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(titleLabel)

        let reveal = Self.button("magnifyingglass", "Show in Finder", #selector(revealClicked), self)
        let open = Self.button("arrow.up.forward.app", "Open", #selector(openClicked), self)
        let closeButton = Self.button("xmark", "Close (Space)", #selector(closeClicked), self)
        let buttons = NSStackView(views: [reveal, open, closeButton])
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(buttons)

        let preview = QLPreviewView(frame: .zero, style: .normal)
        preview?.autostarts = true
        preview?.shouldCloseWithWindow = false
        if let preview = preview {
            preview.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
                preview.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
                preview.topAnchor.constraint(equalTo: effect.topAnchor, constant: 38),
                preview.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
            ])
        }
        previewView = preview

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: effect.topAnchor, constant: 19),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            buttons.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        return panel
    }

    private static func button(_ symbol: String, _ tip: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let b = NSButton(title: "", target: target, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        b.isBordered = false
        b.bezelStyle = .inline
        b.imagePosition = .imageOnly
        b.toolTip = tip
        return b
    }

    @objc private func revealClicked() {
        guard let url = url else { return }
        Launcher.reveal([url])
    }

    @objc private func openClicked() {
        guard let url = url else { return }
        Launcher.open(url: url)
        close()
        onOpen?()
    }

    @objc private func closeClicked() {
        close()
    }
}
