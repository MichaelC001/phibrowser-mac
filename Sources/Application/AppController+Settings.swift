// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import Combine
import Settings

/// Tracks the context from which the Settings window was last presented so
/// individual panes can adapt their UI (e.g. hide app-wide preferences when
/// invoked from an incognito window).
@MainActor
final class SettingsPresentationState: ObservableObject {
    static let shared = SettingsPresentationState()

    @Published var openedFromIncognito: Bool = false

    private init() {}
}

extension AppController {
    
    private func panes() -> [SettingsPane] {
        var panes: [SettingsPane] =
        [AccountSettingViewController(),
         GeneralSettingViewController(),
         ProfilesSettingViewController(),
         SpacesSettingViewController(),
         AISettingsViewController(),
         IMChannelsSettingViewController(),
         ShortcutsSettingViewController(),
        ]
        if PhiPreferences.AgentSpaces.skillFeatureEnabled {
            panes.append(DeveloperSettingViewController())
        }
        return panes
    }
    
    /// Returns the shared settings window controller, creating it on first access.
    /// Refreshes the presentation context (e.g. incognito source) on every call so
    /// individual panes see the right state regardless of which entry point was used.
    @discardableResult
    func ensureSettingsWindowController() -> SettingsWindowController {
        refreshSettingsPresentationState()

        if let existingController = settingsWindowController {
            return existingController
        }
        
        let controller = SettingsWindowController(panes: panes(),
                                                  style: .toolbarItems,
                                                  animated: false,
                                                  hidesToolbarForSingleItem: false)
        settingsWindowController = controller
        
        if let window = controller.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(settingsWindowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
        
        return controller
    }

    private func refreshSettingsPresentationState() {
        Task { @MainActor in
            let isIncognito = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState.isIncognito ?? false
            SettingsPresentationState.shared.openedFromIncognito = isIncognito
        }
    }
    
    /// Shows the settings window, optionally jumping to a specific pane.
    ///
    /// `SettingsWindowController.show(pane:)` re-centers the window and then
    /// restores the autosaved frame on every call. When the window is already
    /// on screen that discards any position the user dragged it to (the frame
    /// autosave can lag behind the move), so the popup visibly jumps. Capture
    /// the current top-left before showing and put it back afterwards; the
    /// top-left anchor keeps pane-switch height changes looking native.
    @discardableResult
    func showSettings(pane paneIdentifier: Settings.PaneIdentifier? = nil) -> SettingsWindowController {
        let controller = ensureSettingsWindowController()

        let visibleTopLeft: NSPoint? = {
            guard let window = controller.window, window.isVisible else { return nil }
            return NSPoint(x: window.frame.minX, y: window.frame.maxY)
        }()

        controller.show(pane: paneIdentifier)

        if let visibleTopLeft {
            controller.window?.setFrameTopLeftPoint(visibleTopLeft)
        }

        return controller
    }

    @MainActor
    @objc func showPreferences(_ sender: Any?) {
        let controller = showSettings()
        controller.window?.orderFront(self)
    }
    
    @objc private func settingsWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsWindowController?.window else {
            return
        }
        
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: closingWindow
        )
        
        settingsWindowController = nil
    }
    
}
