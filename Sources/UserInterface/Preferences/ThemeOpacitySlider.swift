// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

// Overlay-opacity slider shared by the General pane (default Space) and the
// Spaces pane (per-Space). Extracted from GeneralSettingView so both settings
// panes drive the same control and slider↔opacity mapping.

func normalizedThemeSliderTrackColor(from color: NSColor) -> NSColor {
    let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
    return resolvedColor.withAlphaComponent(1)
}

/// Linear mapping between the overlay slider position (0...100) and the actual
/// allowed opacity percentage (10...80). Keeping the slider on a full 0...100
/// range lets the knob travel to both visual ends, while the underlying overlay
/// alpha is constrained to a tasteful sub-range.
enum OverlayOpacityScale {
    static let minOpacityPercent: Double = 10
    static let maxOpacityPercent: Double = 80

    static func opacityPercent(forSlider sliderValue: Double) -> Double {
        let clamped = min(max(sliderValue, 0), 100)
        return minOpacityPercent + (maxOpacityPercent - minOpacityPercent) * (clamped / 100)
    }

    static func sliderValue(forOpacityPercent opacityPercent: Double) -> Double {
        let clamped = min(max(opacityPercent, minOpacityPercent), maxOpacityPercent)
        return (clamped - minOpacityPercent) / (maxOpacityPercent - minOpacityPercent) * 100
    }
}

struct ThemeOpacitySliderView: NSViewRepresentable {
    @Binding var value: Double
    let trackColor: NSColor
    let borderColor: NSColor
    /// Control width; the track image is generated at this width so the
    /// gradient is never stretched. Callers must match their `.frame` width.
    var width: CGFloat = 324

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    private static let knobDiameter: CGFloat = 18

    func makeNSView(context: Context) -> CustomSlider {
        let slider = ThemeOpacityCustomSlider(frame: NSRect(origin: .zero, size: NSSize(width: width, height: 20)))
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = value
        slider.isContinuous = true
        slider.barSize = NSSize(width: width, height: 10)
        slider.knobSize = NSSize(width: Self.knobDiameter, height: Self.knobDiameter)
        slider.knobView = ThemeOpacitySliderKnobView(
            frame: NSRect(origin: .zero, size: NSSize(width: Self.knobDiameter, height: Self.knobDiameter)),
            borderColor: borderColor
        )
        slider.trackImage = makeTrackImage(color: trackColor, borderColor: borderColor)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.sliderValueChanged(_:))
        return slider
    }

    func updateNSView(_ slider: CustomSlider, context: Context) {
        slider.trackImage = makeTrackImage(color: trackColor, borderColor: borderColor)
        if let knobView = slider.knobView as? ThemeOpacitySliderKnobView {
            knobView.borderColor = borderColor
        }
        if slider.doubleValue != value {
            AppLogDebug("[OverlayOpacity] updateNSView push slider \(slider.doubleValue) → \(value)")
            slider.doubleValue = value
        }
    }

    private func makeTrackImage(color: NSColor, borderColor: NSColor) -> NSImage {
        let size = NSSize(width: width, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2)
        path.addClip()

        let baseColor = normalizedThemeSliderTrackColor(from: color)
        let startColor = baseColor.withAlphaComponent(OverlayOpacityScale.minOpacityPercent / 100)
        let endColor = baseColor.withAlphaComponent(OverlayOpacityScale.maxOpacityPercent / 100)
        let gradient = NSGradient(starting: startColor, ending: endColor)
        gradient?.draw(in: path, angle: 0)

        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        image.unlockFocus()
        return image
    }

    final class Coordinator: NSObject {
        @Binding private var value: Double

        init(value: Binding<Double>) {
            self._value = value
        }

        @objc func sliderValueChanged(_ sender: NSSlider) {
            AppLogDebug("[OverlayOpacity] NSSlider action value=\(sender.doubleValue)")
            value = sender.doubleValue
        }
    }
}

private final class ThemeOpacitySliderKnobView: NSView {
    var borderColor: NSColor {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        self.borderColor = ThemedColor.border.resolved()
        super.init(frame: frameRect)
        wantsLayer = true
    }

    init(frame frameRect: NSRect, borderColor: NSColor) {
        self.borderColor = borderColor
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        self.borderColor = ThemedColor.border.resolved()
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Inset by half the stroke width so the 1pt border sits exactly on the
        // view edge, leaving no visible gap when the knob rests at the bar end.
        let strokeWidth: CGFloat = 1
        let circleRect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.set()

        let fillPath = NSBezierPath(ovalIn: circleRect)
        NSColor.white.setFill()
        fillPath.fill()

        NSGraphicsContext.current?.saveGraphicsState()
        NSShadow().set()
        borderColor.setStroke()
        fillPath.lineWidth = strokeWidth
        fillPath.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// Slider variant whose cell positions the knob using the configured `knobSize`
/// instead of AppKit's default `knobThickness` (~21pt). Other CustomSlider
/// callers use a 20pt knob, where the resulting ~0.5pt gap is invisible; our
/// 16pt knob produces a ~2.5pt visible gap, so we take over the layout.
private final class ThemeOpacityCustomSlider: CustomSlider {
    override class var cellClass: AnyClass? {
        get { ThemeOpacitySliderCell.self }
        set { _ = newValue }
    }
}

private final class ThemeOpacitySliderCell: ImageSliderCell {
    override var knobThickness: CGFloat {
        knobSize?.width ?? super.knobThickness
    }

    /// Span the whole control width so the gradient track image (also generated
    /// at full width) is not squeezed into AppKit's default knob padding.
    override func barRect(flipped: Bool) -> NSRect {
        guard let controlView else {
            return super.barRect(flipped: flipped)
        }
        let bounds = controlView.bounds
        let drawHeight = barSize?.height ?? bounds.height
        return NSRect(
            x: 0,
            y: (bounds.height - drawHeight) / 2.0,
            width: bounds.width,
            height: drawHeight
        )
    }

    override func knobRect(flipped: Bool) -> NSRect {
        guard let controlView else {
            return super.knobRect(flipped: flipped)
        }
        let bounds = controlView.bounds
        let knobWidth = knobSize?.width ?? super.knobThickness
        let knobHeight = knobSize?.height ?? bounds.height
        let denominator = maxValue - minValue
        let ratio: CGFloat = denominator > 0 ? CGFloat((doubleValue - minValue) / denominator) : 0
        let travel = max(0, bounds.width - knobWidth)
        let x = ratio * travel
        let y = (bounds.height - knobHeight) / 2.0
        return NSRect(x: x, y: y, width: knobWidth, height: knobHeight)
    }
}
