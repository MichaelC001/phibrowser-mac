// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Security
import WebKit

/// The on-disk half of the account deletion finalize: everything Phi keeps
/// on this Mac outside the credential layer (which
/// `AuthManager.clearLocalAccountData()` owns).
///
/// Three pieces, in order:
/// 1. The data roots (user data, caches, preferences) plus the Time
///    Machine upgrade-snapshot root — whose snapshots hold copies of the
///    very data being erased, and whose pending-restore markers must not
///    survive to resurrect it — via `UserDataRemoval`. First on purpose:
///    it lands the removal's persistent markers (the moved-aside
///    directories and the cleaner PID file) milliseconds after the user's
///    confirmation, so a crash anywhere later in the finalize leaves a
///    marked, startup-recoverable removal instead of untouched data —
///    without this ordering the unprotected window would span the website
///    data sweep's 10-second ceiling. What a late crash can still leave
///    behind — website data and credentials — are both accepted residue
///    directions (the sweep-timeout residue below, and the credential
///    layer's 401 forced sign-out on the next launch).
/// 2. WKWebView website data (`~/Library/WebKit/<bundleId>`): the account
///    web windows keep their signed-in sessions there, outside the data
///    roots above. Cleared in-process before the quit, with the same
///    all-types sweep as the debug menu's Login Status item — but bounded:
///    the finalize promised a quit, so a stalled WebKit daemon must not
///    hold it hostage.
/// 3. The "Phi Safe Storage" keychain item — Chromium's profile encryption
///    key. Harmless once the profiles are gone, but it is Phi residue.
///    Skipped when a sibling channel (canary ↔ release) still has data:
///    both channels share the one item, so deleting it would strand the
///    sibling's encrypted profile data.
///
/// `beginRemoval` drops the standard defaults domain, and any later write
/// would resurrect it in cfprefsd. The removal's own steps are safe — the
/// sweep and the keychain delete were probe-verified to write no defaults
/// (ticket 16's pre-verification) — but the sweep's suspension leaves the
/// rest of the app interactive: the finalize dialog is a sheet on one
/// window, so a menu toggle or a layout observer elsewhere can still
/// write the domain, and on a crash-free run nothing would clear that
/// write again (the cleaner deletes only the plist file, which cfprefsd
/// survives). `removeAll` therefore drops the domain once more on the way
/// out, leaving only the credential clear between the re-drop and the
/// quit: it touches keychain items and per-account files only — the
/// latter are path-based writes into the data tree that was just moved
/// aside, so they fail harmlessly and recreate nothing at the canonical
/// paths.
@MainActor
enum AccountDeletionLocalDataRemoval {
    static func removeAll() async {
        let targets = UserDataRemoval.Targets.currentProductIncludingTimeMachine
        UserDataRemoval.beginRemoval(of: targets)
        await removeWebsiteData()
        removeSafeStorageKeychainItem()
        UserDefaults.standard.removePersistentDomain(forName: targets.preferencesDomain)
    }

    /// How long the finalize waits for the WKWebsiteDataStore sweep. The
    /// sweep runs in WebKit's storage daemons and offers no cancellation,
    /// so without a bound a stalled daemon would leave the finalize dialog
    /// spinning with no enabled buttons — and a force-quit there would
    /// abandon the whole local cleanup. On timeout the finalize proceeds:
    /// the caches target already covers WebKit's cache tree, and leftover
    /// website data is the accepted residue direction.
    static let websiteDataRemovalTimeout: TimeInterval = 10

    private static func removeWebsiteData() async {
        let finished = await awaitWithDeadline(seconds: websiteDataRemovalTimeout) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
                let dataStore = WKWebsiteDataStore.default()
                dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                    dataStore.removeData(ofTypes: dataTypes, for: records) {
                        AppLogInfo("🗑️ [AccountDeletion] WKWebView website data cleared (\(records.count) records)")
                        continuation.resume()
                    }
                }
            }
        }
        if !finished {
            AppLogWarn(
                "🗑️ [AccountDeletion] WKWebView website data removal timed out after \(Int(websiteDataRemovalTimeout))s; continuing the finalize"
            )
        }
    }

    /// Runs the operation but stops waiting after `seconds`; returns
    /// whether it finished in time. Unstructured on purpose: the WebKit
    /// callbacks ignore cancellation, and a task group would await its
    /// children on exit anyway, defeating the deadline. The loser's late
    /// resume is dropped by the one-shot guard.
    static func awaitWithDeadline(
        seconds: TimeInterval,
        of operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let firstResult = OneShotResume(continuation)
            Task { @MainActor in
                await operation()
                firstResult.resume(with: true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                firstResult.resume(with: false)
            }
        }
    }

    /// Chromium stores the profile encryption key as a generic password
    /// with service "Phi Safe Storage" and account "Phi" (see
    /// `components/os_crypt/common/keychain_password_mac.mm` in the fork).
    /// The names are compile-time constants shared by every Phi channel,
    /// so the item is only deleted when no sibling channel still keeps a
    /// data root — deleting it under a live sibling would make that
    /// channel's encrypted cookies and passwords undecryptable. A missing
    /// item is fine — it only exists once a profile encrypted something.
    private static func removeSafeStorageKeychainItem() {
        if let sibling = siblingProductDataRootURL(),
           FileManager.default.fileExists(atPath: sibling.path) {
            AppLogInfo(
                "🗑️ [AccountDeletion] Keeping the Safe Storage keychain item: sibling channel data exists at \(sibling.path)"
            )
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Phi Safe Storage",
            kSecAttrAccount as String: "Phi",
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogWarn("🗑️ [AccountDeletion] Failed to delete the Safe Storage keychain item: \(status)")
        }
    }

    /// The bundle identifier of the other Phi channel: canary and release
    /// pair up by inserting or removing the ".canary" component
    /// (com.phibrowser.Mac ↔ com.phibrowser.canary.Mac). Nil when the
    /// identifier has no dot to pivot on.
    nonisolated static func siblingProductBundleID(for bundleID: String) -> String? {
        if bundleID.contains(".canary.") {
            return bundleID.replacingOccurrences(of: ".canary.", with: ".")
        }
        guard let lastDot = bundleID.lastIndex(of: ".") else { return nil }
        return String(bundleID[..<lastDot]) + ".canary" + String(bundleID[lastDot...])
    }

    private static func siblingProductDataRootURL() -> URL? {
        guard let siblingID = siblingProductBundleID(for: FileSystemUtils.bundleId) else {
            return nil
        }
        return URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent(siblingID, isDirectory: true)
    }
}

/// One-shot resumption guard for `awaitWithDeadline`: whichever racer
/// finishes first resumes the continuation, the loser's call is dropped.
private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
