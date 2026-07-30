// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import SnapKit

/// Settings pane for managing Chromium profiles. Mirrors the host/hosting/
/// SwiftUI split used by the other panes; the management UI lives in the
/// SwiftUI `ProfilesSettingsView`.
class ProfilesSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier: Settings.PaneIdentifier = .profiles
    var paneTitle: String = NSLocalizedString("settings.navigation.profilesTitle", value: "Profiles", comment: "Settings - Tab title for profiles management")
    var toolbarItemIcon: NSImage = NSImage(resource: .settingProfileIcon)
    let hostingController = ProfilesSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
