// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// Shared theme state shape used by both the global manager and window-scoped contexts.
public protocol ThemeStateProvider: ThemeSource {
    var currentTheme: Theme { get }
    var currentAppearance: Appearance { get }
    var userAppearanceChoice: UserAppearanceChoice { get }
    var themeAppearancePublisher: PassthroughSubject<(Theme, Appearance), Never> { get }
}

extension ThemeManager: ThemeStateProvider {}

/// Initial theme configuration for a browser window.
public struct BrowserThemeConfiguration {
    public let currentTheme: Theme
    public let userAppearanceChoice: UserAppearanceChoice
    public let mirrorsSharedTheme: Bool
    public let mirrorsSharedAppearance: Bool
    
    public init(
        currentTheme: Theme,
        userAppearanceChoice: UserAppearanceChoice,
        mirrorsSharedTheme: Bool,
        mirrorsSharedAppearance: Bool
    ) {
        self.currentTheme = currentTheme
        self.userAppearanceChoice = userAppearanceChoice
        self.mirrorsSharedTheme = mirrorsSharedTheme
        self.mirrorsSharedAppearance = mirrorsSharedAppearance
    }
}

/// Resolves the initial theme configuration for a browser window.
enum BrowserThemeConfigurationResolver {
    @MainActor
    static func resolve(isIncognito: Bool) -> BrowserThemeConfiguration {
        if isIncognito {
            return BrowserThemeConfiguration(
                currentTheme: .incognito,
                userAppearanceChoice: .dark,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        }
        let manager = ThemeManager.shared
        let theme = resolveTheme(id: manager.currentTheme.id, manager: manager)
        return BrowserThemeConfiguration(
            currentTheme: theme,
            userAppearanceChoice: manager.userAppearanceChoice,
            mirrorsSharedTheme: true,
            mirrorsSharedAppearance: true
        )
    }
    
    @MainActor
    private static func resolveTheme(id: String, manager: ThemeManager) -> Theme {
        if let theme = manager.registeredThemes[id] {
            return theme
        }
        if manager.currentTheme.id == id {
            return manager.currentTheme
        }
        return .default
    }
}

/// Window-scoped theme source for one browser window.
public final class BrowserThemeContext: NSObject, ThemeStateProvider {
    public private(set) var currentTheme: Theme {
        didSet {
            guard currentTheme !== oldValue else { return }
            notifyThemeChange()
        }
    }
    
    public private(set) var userAppearanceChoice: UserAppearanceChoice {
        didSet {
            guard userAppearanceChoice != oldValue else { return }
            notifyAppearanceChange()
        }
    }
    
    public var currentAppearance: Appearance {
        switch userAppearanceChoice {
        case .system:
            return appAppearance
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
    
    public var windowAppearance: NSAppearance? {
        switch userAppearanceChoice {
        case .system:
            return nil
        case .light:
            return Appearance.light.nsAppearance
        case .dark:
            return Appearance.dark.nsAppearance
        }
    }
    
    public var hasFixedWindowAppearance: Bool {
        windowAppearance != nil
    }
    
    public let themePublisher = PassthroughSubject<Theme, Never>()
    public let appearancePublisher = PassthroughSubject<Appearance, Never>()
    public let themeAppearancePublisher = PassthroughSubject<(Theme, Appearance), Never>()
    
    /// Whether changes to the global `ThemeManager.shared.currentTheme` are
    /// mirrored onto this window's theme. Flipped to false by `SpaceManager`
    /// when a Space has an explicit theme override, so a later global theme
    /// switch doesn't clobber the Space's pinned theme. The mirror sink is
    /// installed unconditionally and gates on this flag at fire time, so
    /// callers can toggle this freely after construction.
    public var mirrorsSharedTheme: Bool
    public var mirrorsSharedAppearance: Bool

    /// Recomputes the theme this window should display from its Space's
    /// persisted state (pinned theme + custom overlay opacity) — installed
    /// by `SpaceManager` when it pins a Space theme, and consulted on
    /// global theme publishes so registry-wide edits (e.g. the General
    /// opacity slider rewriting every theme's alpha) reach pinned windows
    /// without losing the Space's own variant. Deliberately NOT applied
    /// inside `setTheme`: transient drivers (the Space push-in theme ramp)
    /// push raw interpolated themes through `setTheme` every frame and
    /// must not be re-clamped.
    public var spaceThemeResolver: (() -> Theme?)?

    private var cancellables = Set<AnyCancellable>()

    @MainActor
    public init(configuration: BrowserThemeConfiguration) {
        self.currentTheme = configuration.currentTheme
        self.userAppearanceChoice = configuration.userAppearanceChoice
        self.mirrorsSharedTheme = configuration.mirrorsSharedTheme
        self.mirrorsSharedAppearance = configuration.mirrorsSharedAppearance
        super.init()
        bindSharedTheme()
    }
    
    public func subscribe(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        action(currentTheme, currentAppearance)
        
        let themeCancellable = themePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                guard let self else { return }
                action(theme, self.currentAppearance)
            }
        
        let appearanceCancellable = appearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appearance in
                guard let self else { return }
                action(self.currentTheme, appearance)
            }
        
        return CompoundObservation([
            themeCancellable as AnyObject,
            appearanceCancellable as AnyObject
        ])
    }
    
    public func setTheme(_ theme: Theme) {
        currentTheme = theme
    }
    
    public func setUserAppearanceChoice(_ choice: UserAppearanceChoice) {
        userAppearanceChoice = choice
    }
    
    @MainActor
    private func bindSharedTheme() {
        let manager = ThemeManager.shared

        // Install both mirror sinks unconditionally; each gates on its own
        // `mirrorsShared*` flag at fire time so callers (e.g. `SpaceManager`
        // applying a Space-pinned theme) can toggle mirroring on/off at
        // runtime without tearing down or re-installing subscriptions.
        manager.themePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                guard let self else { return }
                if self.mirrorsSharedTheme {
                    self.currentTheme = theme
                } else if let resolved = self.spaceThemeResolver?() {
                    // Pinned windows ignore the active theme but must still
                    // pick up edits applied across the whole registry — e.g.
                    // the General opacity slider rewrites every theme's
                    // overlay alpha. Recompute from the Space's persisted
                    // state so those edits reach this window with the
                    // Space's own overlay opacity re-applied on top.
                    self.currentTheme = resolved
                } else if let refreshed = manager.registeredThemes[self.currentTheme.id] {
                    // No resolver installed (e.g. the fixed incognito theme,
                    // which is never registered) — fall back to re-resolving
                    // the pinned id so registry edits still land.
                    self.currentTheme = refreshed
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appearanceDidChange, object: manager)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.mirrorsSharedAppearance else { return }
                let sharedChoice = manager.userAppearanceChoice
                if self.userAppearanceChoice != sharedChoice {
                    self.userAppearanceChoice = sharedChoice
                } else if sharedChoice == .system {
                    self.notifyAppearanceChange()
                }
            }
            .store(in: &cancellables)
    }
    
    private func notifyThemeChange() {
        themePublisher.send(currentTheme)
        themeAppearancePublisher.send((currentTheme, currentAppearance))
    }
    
    private func notifyAppearanceChange() {
        appearancePublisher.send(currentAppearance)
        themeAppearancePublisher.send((currentTheme, currentAppearance))
    }
}

public extension NSWindow {
    var browserThemeContext: BrowserThemeContext? {
        (windowController as? MainBrowserWindowController)?.browserState.themeContext
    }
    
    var themeStateProvider: ThemeStateProvider {
        browserThemeContext ?? ThemeManager.shared
    }
}

public extension NSView {
    var browserThemeContext: BrowserThemeContext? {
        window?.browserThemeContext
    }
    
    var themeStateProvider: ThemeStateProvider {
        browserThemeContext ?? ThemeManager.shared
    }
}

public extension ThemedColor {
    func resolve(in view: NSView?) -> NSColor {
        let provider = view?.themeStateProvider ?? ThemeManager.shared
        let theme = provider.currentTheme
        let appearance = provider.currentAppearance
        return resolver(theme, appearance)
    }
    
    func resolve(in window: NSWindow?) -> NSColor {
        let provider = window?.themeStateProvider ?? ThemeManager.shared
        let theme = provider.currentTheme
        let appearance = provider.currentAppearance
        return resolver(theme, appearance)
    }
}
