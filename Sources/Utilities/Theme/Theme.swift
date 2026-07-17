// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// A semantic color pair for light and dark appearance.
public struct ColorPair: Hashable {
    public let light: NSColor
    public let dark: NSColor
    
    public init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
    }
    
    /// Initializes a color pair that uses the same color for both appearances.
    public init(_ color: NSColor) {
        self.light = color
        self.dark = color
    }
    
    /// Resolves the color for a specific appearance.
    public func color(for appearance: Appearance) -> NSColor {
        appearance.isDark ? dark : light
    }
}

enum ThemeDefaults {
    static let overlayLightOpacity: CGFloat = 0.4
    static let overlayDarkOpacity: CGFloat = 0.8
}

struct StoredRGBAColor: Codable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
        self.init(
            red: resolvedColor.redComponent,
            green: resolvedColor.greenComponent,
            blue: resolvedColor.blueComponent,
            alpha: resolvedColor.alphaComponent
        )
    }

    func asColor() -> NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

struct StoredColorPair: Codable, Equatable {
    let light: StoredRGBAColor
    let dark: StoredRGBAColor

    init(light: StoredRGBAColor, dark: StoredRGBAColor) {
        self.light = light
        self.dark = dark
    }

    init(_ pair: ColorPair) {
        self.init(light: StoredRGBAColor(pair.light), dark: StoredRGBAColor(pair.dark))
    }

    func asColorPair() -> ColorPair {
        ColorPair(light: light.asColor(), dark: dark.asColor())
    }
}

struct ThemeEditableColors: Codable, Equatable {
    let windowOverlayBackground: StoredColorPair
    let windowBackground: StoredColorPair
    let themeColor: StoredColorPair
    let extensionActonColor: StoredColorPair

    func updatingOverlayOpacity(_ opacity: CGFloat, for appearance: Appearance) -> ThemeEditableColors {
        let clampedOpacity = min(max(opacity, 0), 1)
        let updatedOverlayPair: StoredColorPair

        switch appearance {
        case .light:
            updatedOverlayPair = StoredColorPair(
                light: StoredRGBAColor(
                    red: windowOverlayBackground.light.red,
                    green: windowOverlayBackground.light.green,
                    blue: windowOverlayBackground.light.blue,
                    alpha: clampedOpacity
                ),
                dark: windowOverlayBackground.dark
            )
        case .dark:
            updatedOverlayPair = StoredColorPair(
                light: windowOverlayBackground.light,
                dark: StoredRGBAColor(
                    red: windowOverlayBackground.dark.red,
                    green: windowOverlayBackground.dark.green,
                    blue: windowOverlayBackground.dark.blue,
                    alpha: clampedOpacity
                )
            )
        }

        return ThemeEditableColors(
            windowOverlayBackground: updatedOverlayPair,
            windowBackground: windowBackground,
            themeColor: themeColor,
            extensionActonColor: extensionActonColor
        )
    }
}

struct ThemeSnapshot: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let id: String
    let name: String
    let colors: ThemeEditableColors

    init(
        version: Int = Self.currentVersion,
        id: String,
        name: String,
        colors: ThemeEditableColors
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.colors = colors
    }

    func updatingOverlayOpacity(_ opacity: CGFloat, for appearance: Appearance) -> ThemeSnapshot {
        ThemeSnapshot(
            version: version,
            id: id,
            name: name,
            colors: colors.updatingOverlayOpacity(opacity, for: appearance)
        )
    }

    func makeTheme() -> Theme {
        let theme = Theme(id: id, name: name)
        theme.applyEditableColors(colors)
        return theme
    }
}

/// Theme definition backed by semantic color roles.
public class Theme: NSObject {
    public let id: String
    public let name: String
    private var colorPalette: [ColorRole: ColorPair]
    
    public init(id: String, name: String, colorPalette: [ColorRole: ColorPair] = [:]) {
        self.id = id
        self.name = name
        self.colorPalette = colorPalette
        super.init()
    }
    
    /// Resolves a color for the given role and appearance.
    public func color(for role: ColorRole, appearance: Appearance) -> NSColor {
        guard let pair = colorPalette[role] else {
            return DefaultColors.color(for: role, appearance: appearance)
        }
        return pair.color(for: appearance)
    }

    public func colorPair(for role: ColorRole) -> ColorPair {
        colorPalette[role] ?? DefaultColors.colorPair(for: role)
    }
    
    /// Sets the color pair for a semantic role.
    public func setColor(_ pair: ColorPair, for role: ColorRole) {
        colorPalette[role] = pair
    }
    
    /// Sets light and dark colors for a semantic role.
    public func setColor(light: NSColor, dark: NSColor, for role: ColorRole) {
        colorPalette[role] = ColorPair(light: light, dark: dark)
    }

    /// Full palette copy carrying the same id/name. Used to derive per-window
    /// variants (e.g. a Space's custom overlay opacity) without mutating the
    /// registered instance. Not a snapshot round-trip: `makeSnapshot()` only
    /// carries the four editable roles, which would drop the rest of a
    /// built-in theme's palette.
    public func duplicating() -> Theme {
        Theme(id: id, name: name, colorPalette: colorPalette)
    }

    public func windowOverlayOpacity(for appearance: Appearance) -> CGFloat {
        color(for: .windowOverlayBackground, appearance: appearance).alphaComponent
    }

    public func setWindowOverlayOpacity(_ opacity: CGFloat, for appearance: Appearance) {
        let clampedOpacity = min(max(opacity, 0), 1)
        let existingPair = colorPair(for: .windowOverlayBackground)

        switch appearance {
        case .light:
            setColor(
                light: existingPair.light.withAlphaComponent(clampedOpacity),
                dark: existingPair.dark,
                for: .windowOverlayBackground
            )
        case .dark:
            setColor(
                light: existingPair.light,
                dark: existingPair.dark.withAlphaComponent(clampedOpacity),
                for: .windowOverlayBackground
            )
        }
    }

    func makeSnapshot() -> ThemeSnapshot {
        ThemeSnapshot(
            id: id,
            name: name,
            colors: ThemeEditableColors(
                windowOverlayBackground: StoredColorPair(colorPair(for: .windowOverlayBackground)),
                windowBackground: StoredColorPair(colorPair(for: .windowBackground)),
                themeColor: StoredColorPair(colorPair(for: .themeColor)),
                extensionActonColor: StoredColorPair(colorPair(for: .extensionActonColor))
            )
        )
    }

    func applyEditableColors(_ editableColors: ThemeEditableColors) {
        setColor(editableColors.windowOverlayBackground.asColorPair(), for: .windowOverlayBackground)
        setColor(editableColors.windowBackground.asColorPair(), for: .windowBackground)

        let themeColorPair = editableColors.themeColor.asColorPair()
        setColor(themeColorPair, for: .themeColor)
        setColor(editableColors.extensionActonColor.asColorPair(), for: .extensionActonColor)
        setColor(
            light: themeColorPair.light.adjustingBrightness(percent: -5),
            dark: themeColorPair.dark.adjustingBrightness(percent: 5),
            for: .themeColorOnHover
        )
    }
    
    // MARK: - Hashable
    
    public override var hash: Int {
        id.hashValue
    }
    
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Theme else { return false }
        return id == other.id
    }
}

// MARK: - Default Theme

public extension Theme {
    /// Default built-in theme.
    static let `default` = Theme.pure
}

extension NSColor {
    func adjustingBrightness(percent delta: CGFloat) -> NSColor {
        let color = usingColorSpace(.extendedSRGB) ?? self
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let adjustedBrightness = min(max(brightness + (delta / 100), 0), 1)
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: adjustedBrightness, alpha: alpha)
    }
}
