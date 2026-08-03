// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Security

enum PhiUninstallSignatureVerifier {
    static let expectedTeamID = "87DQ3HMK5G"

    static func verifyAppBundle(
        at bundleURL: URL,
        expectedBundleID: String,
        expectedTeamID: String = PhiUninstallSignatureVerifier.expectedTeamID
    ) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
            return false
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let teamID = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }

        return identifier == expectedBundleID && teamID == expectedTeamID
    }
}
