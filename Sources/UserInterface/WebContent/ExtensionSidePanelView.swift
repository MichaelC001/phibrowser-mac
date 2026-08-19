// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit

/// Chrome for the extension side panel slot: a header (extension icon, name,
/// close button) above the adopted Chromium panel view, wrapped in the same
/// rounded / 1pt-bordered / theme-backed card the AI Chat panel uses, plus an
/// invisible drag divider on the content-facing edge for resizing (same
/// pattern as `AgentTranscriptDockView`). Installed into the window-level
/// right slot by `WebContentContainerViewController`. Open/close state stays
/// owned by Chromium — the close button only *requests* closure via
/// `onCloseRequested`, so the extension observes its normal event sequence.
final class ExtensionSidePanelView: NSView {
    /// The header close button was clicked. Routed by the container to
    /// `BrowserState.requestExtensionSidePanelClose()`.
    var onCloseRequested: (() -> Void)?

    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 800
    private static let headerHeight: CGFloat = 36

    /// The adopted Chromium panel NSView mounts here, below the header.
    /// WebContentHostView strips AppKit's vibrancy compositingFilter from
    /// the adopted Chromium view.
    let contentHostView = WebContentHostView()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!

    /// The user-chosen width — the width constraint's constant, not the
    /// frame (which a 999-priority squeeze can compress below it). Read by
    /// the container on detach for the per-window width memory.
    var preferredWidth: CGFloat { widthConstraint.constant }

    init(initialWidth: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Card looks aligned with the AI Chat panel (see
        // EmbeddedChatViewController.viewDidLoad): rounded continuous
        // corners, 1pt themed border, themed background.
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        phiLayer?.setBorderColor(.border)
        phiLayer?.backgroundColor = NSColor.white <> NSColor.black

        let headerView = NSView()
        addSubview(headerView)
        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Self.headerHeight)
        }

        iconView.imageScaling = .scaleProportionallyUpOrDown
        headerView.addSubview(iconView)
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.phi.setTextColor(.textPrimary)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerView.addSubview(nameLabel)

        let closeLabel = NSLocalizedString(
            "browser.extensionSidePanel.close",
            value: "Close Side Panel",
            comment: "Extension side panel - Tooltip and accessibility label for the header control that closes the panel")
        let closeConfig = HoverableButtonConfig(
            imageSize: NSSize(width: 14, height: 14),
            systemName: "xmark",
            hoverBackgroundColor: .hover,
            cornerRadius: 5)
        let closeButton = HoverableButtonNSView(config: closeConfig,
                                                target: self,
                                                selector: #selector(closeButtonClicked))
        closeButton.toolTip = closeLabel
        closeButton.setAccessibilityLabel(closeLabel)
        headerView.addSubview(closeButton)
        closeButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(26)
        }

        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(closeButton.snp.leading).offset(-8)
        }

        let headerSeparator = NSView()
        headerSeparator.wantsLayer = true
        headerSeparator.phiLayer?.setBackgroundColor(.separator)
        addSubview(headerSeparator)
        headerSeparator.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }

        contentHostView.wantsLayer = true
        addSubview(contentHostView)
        contentHostView.snp.makeConstraints { make in
            make.top.equalTo(headerSeparator.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        let divider = DividerView()
        divider.currentWidth = { [weak self] in self?.widthConstraint.constant ?? 0 }
        divider.onDrag = { [weak self] proposed in
            self?.setPreferredWidth(proposed)
        }
        addSubview(divider)
        divider.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(6)
        }

        // Below-required so an extreme window shrink compresses the panel
        // instead of raising an unsatisfiable-constraints exception (same
        // treatment as AgentTranscriptDockView's size constraint).
        widthConstraint = widthAnchor.constraint(
            equalToConstant: Self.clampedWidth(initialWidth))
        widthConstraint.priority = NSLayoutConstraint.Priority(999)
        widthConstraint.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func clampedWidth(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, minWidth), maxWidth)
    }

    /// Applies a proposed width, clamped to `minWidth...maxWidth`. Drag
    /// entry point; also usable by tests.
    func setPreferredWidth(_ proposed: CGFloat) {
        widthConstraint.constant = Self.clampedWidth(proposed)
    }

    /// Refreshes the header for the shown extension. Called on every bridge
    /// push, so a content replacement (another extension's panel) updates
    /// the identity row in place.
    func updateHeader(displayName: String, iconPNG: Data?) {
        nameLabel.stringValue = displayName
        if let iconPNG, let icon = NSImage(data: iconPNG) {
            iconView.image = icon
        } else {
            // No icon in the payload — fall back to the generic extension
            // glyph rather than an empty gap.
            iconView.image = NSImage(systemSymbolName: "puzzlepiece.extension",
                                     accessibilityDescription: nil)
        }
    }

    @objc private func closeButtonClicked() {
        onCloseRequested?()
    }

    /// The invisible drag strip along the panel's content-facing (leading)
    /// edge. Same interaction as `AgentTranscriptDockView.DividerView`: the
    /// panel widens as the divider moves left.
    private final class DividerView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var currentWidth: (() -> CGFloat)?
        private var dragOrigin: NSPoint = .zero
        private var originalWidth: CGFloat = 0

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = event.locationInWindow
            originalWidth = currentWidth?() ?? 0
        }

        override func mouseDragged(with event: NSEvent) {
            let delta = dragOrigin.x - event.locationInWindow.x
            onDrag?(originalWidth + delta)
        }
    }
}
