// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

#if DEBUG
import Cocoa
import SnapKit

/// Uses the production renderer but keeps all selections local to this window.
final class HolographicCardDebugViewController: NSViewController {
    let cardView = HolographicCardView()
    private let palette = NSPopUpButton()
    private let texture = NSPopUpButton()
    private let ornament = NSPopUpButton()
    private let details = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 640))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        cardView.animatesIdleTilt = true
        cardView.name = "Mike"
        cardView.memberID = "103"
        cardView.joinedDate = "2026.10"
        view.addSubview(cardView)
        cardView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalToSuperview().offset(65)
            make.width.equalTo(292)
            make.height.equalTo(423)
        }
        let heading = NSTextField(labelWithString: "Holographic Card")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Production card renderer · Preview only")
        subtitle.textColor = .secondaryLabelColor
        palette.addItems(withTitles: HolographicCardStyle.Palette.allCases.map { "\($0.rawValue.capitalized) / \($0.themeID)" })
        texture.addItems(withTitles: HolographicCardStyle.Texture.allCases.map { $0.rawValue.capitalized })
        ornament.addItems(withTitles: HolographicCardStyle.Ornament.allCases.map { $0.rawValue.capitalized })
        for (control, label) in [(palette, "Theme"), (texture, "Background texture"), (ornament, "Guilloche ornament")] {
            control.target = self
            control.action = #selector(selectionChanged)
            control.setAccessibilityLabel(label)
            control.snp.makeConstraints { $0.width.equalTo(300) }
        }
        let random = NSButton(title: "Randomize", target: self, action: #selector(randomize))
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(reset))
        let replay = NSButton(title: "Replay Entrance", target: self, action: #selector(replay))
        let export = NSButton(title: "Export Front PNG…", target: self, action: #selector(exportFront))
        let animate = NSButton(checkboxWithTitle: "Animate", target: self, action: #selector(toggleAnimation(_:)))
        animate.state = .on
        let back = NSButton(checkboxWithTitle: "Show Reverse", target: self, action: #selector(toggleBack(_:)))
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.textColor = .secondaryLabelColor
        details.isSelectable = true
        let stack = NSStackView(views: [heading, subtitle,
            NSTextField(labelWithString: "Theme"), palette,
            NSTextField(labelWithString: "Background texture"), texture,
            NSTextField(labelWithString: "Guilloche ornament"), ornament,
            NSStackView(views: [random, reset]), NSStackView(views: [replay, export]),
            NSStackView(views: [animate, back]), details])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        view.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.equalTo(cardView.snp.trailing).offset(75)
            make.trailing.equalToSuperview().inset(40)
            make.centerY.equalToSuperview()
        }
        refresh()
    }

    @objc private func selectionChanged() {
        cardView.style = HolographicCardStyle(
            palette: HolographicCardStyle.Palette.allCases[palette.indexOfSelectedItem],
            texture: HolographicCardStyle.Texture.allCases[texture.indexOfSelectedItem],
            ornament: HolographicCardStyle.Ornament.allCases[ornament.indexOfSelectedItem])
        refresh()
    }

    @objc private func randomize() { cardView.style = .random(); refresh() }
    @objc private func reset() { cardView.style = .default; refresh() }
    @objc private func replay() { cardView.replayEntrance() }
    @objc private func toggleAnimation(_ sender: NSButton) { cardView.isPresentationActive = sender.state == .on }
    @objc private func toggleBack(_ sender: NSButton) { cardView.showsReverse = sender.state == .on }

    private func refresh() {
        let style = cardView.style
        palette.selectItem(at: HolographicCardStyle.Palette.allCases.firstIndex(of: style.palette)!)
        texture.selectItem(at: HolographicCardStyle.Texture.allCases.firstIndex(of: style.texture)!)
        ornament.selectItem(at: HolographicCardStyle.Ornament.allCases.firstIndex(of: style.ornament)!)
        let colors = style.palette.colors.map { String(format: "#%06X", $0) }.joined(separator: " · ")
        details.stringValue = "\(colors)\n292 × 423 · Radius 28 · Angle 200°\nTexture 72% · Shine 78% · Contrast 1.18\nHover or use arrow keys to inspect the light."
    }

    @objc private func exportFront() {
        Task { await exportImage() }
    }

    private func exportImage() async {
        let style = cardView.style
        guard let tiff = await cardView.frontImage()?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(style.palette.rawValue)-\(style.texture.rawValue)-\(style.ornament.rawValue).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { NSApp.presentError(error) }
        }
    }
}
#endif
