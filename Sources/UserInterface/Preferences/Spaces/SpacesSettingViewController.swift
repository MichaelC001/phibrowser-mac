// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

/// Settings pane for managing Chromium profiles and their Spaces. Mirrors the
/// host/hosting/SwiftUI split used by the other panes (e.g. Shortcuts): this
/// `SettingsPane` is the AppKit toolbar entry, the heavy lifting lives in the
/// SwiftUI `SpacesSettingsView` hosted by `SpacesSettingHostingViewController`.
class SpacesSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .spaces
    var paneTitle: String = NSLocalizedString("settings.navigation.spacesTitle", value: "Spaces", comment: "Settings - Tab title for profiles and spaces management")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingSpaceIcon)
    let hostingController = SpacesSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
