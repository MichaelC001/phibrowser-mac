// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import Kingfisher
import PostHog
class Account {
    let userID: String
    let userInfo: User?
    lazy var localStorage: LocalStore = {
        // Under UI testing the store is redirected to a throwaway per-launch
        // temp directory so tests never read or mutate the real account's
        // Spaces, bookmarks, or pinned tabs. See `uiTestStoreDirectoryURL`.
        if let testStoreURL = Account.uiTestStoreDirectoryURL {
            return LocalStore(account: self, storeDirectoryURL: testStoreURL)
        }
        return LocalStore(account: self)
    }()
    private(set) lazy var userDefaults: AccountUserDefaults = {
        AccountUserDefaults(account: self)
    }()
    
    init(userID: String, userInfo: User? = nil) {
        self.userID = userID
        self.userInfo = userInfo
        if let userInfo {
            if let sub = userInfo.sub {
                PostHogSDK.shared.identify(sub)
            }
        }
        
        SentryService.configureUser(self)
    }
    
    var userDataStorage: URL {
        let phiDataSupportURL = URL(filePath:  FileSystemUtils.phiBrowserDataDirectory())
        return phiDataSupportURL
            .appendingPathComponent("users")
            .appendingPathComponent(userID)
    }
}

extension Account {
    static let defaultUid = "default-account-id"
    static var defaultAccount: Account {
        return Account(userID: defaultUid)
    }

    /// A unique-per-launch temp directory for the `LocalStore` when the app is
    /// launched for UI testing (`-uitest`); otherwise nil. Isolating the store
    /// keeps UI tests from reading or writing the real account's Spaces,
    /// bookmarks, and pinned tabs — the Chromium `--user-data-dir` does not
    /// cover this Swift-side, per-account store. Computed once per process.
    static let uiTestStoreDirectoryURL: URL? = {
        guard ProcessInfo.processInfo.arguments.contains("-uitest") else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "PhiUITestStore-\(ProcessInfo.processInfo.globallyUniqueString)",
                isDirectory: true
            )
    }()
}

class AccountController {
    static let shared = AccountController()
    var account: Account? {
        didSet {
            NotificationCenter.default.post(name: .mainAccountChanged, object: account)
            /// FIXME: Chromium builds the main menu before the account exists, but shortcut overrides
            /// are account-scoped. Reloading here works, but this probably deserves a cleaner hook.
            Shortcuts.reloadOverrides()
            AppLogInfo("account controller created: \(String(describing: account?.userID))")
            prefetchProfile(for: account)
        }
    }

    /// Best-effort refresh of the existing per-account profile cache. The
    /// conditional write preserves a newer profile saved while this GET was
    /// in flight, notably the SetName PUT response during onboarding.
    private func prefetchProfile(for account: Account?) {
        guard let account else { return }
        let key = AccountUserDefaults.DefaultsKey.cachedProfile.rawValue
        let cachedDataAtStart = account.userDefaults.data(forKey: key)
        var cachedProfile: Profile? = account.userDefaults.codableValue(forKey: key)
        if cachedProfile?.auth0_id != account.userID {
            cachedProfile = nil
        }

        // Warm the avatar store from Kingfisher's disk cache right away:
        // the GET below (and the forced refetch after it) can be slow or
        // fail offline, while the Chromium settings bridge may query at
        // any moment. The network refresh overwrites this with fresher
        // bytes once it lands.
        if let picture = cachedProfile?.picture, let url = URL(string: picture) {
            // Hop before reading the generation so the capture happens
            // on the main thread alongside every other generation access.
            DispatchQueue.main.async {
                self.warmAvatarFromCache(url: url, for: account, generation: self.avatarGeneration)
            }
        }

        Task {
            guard let response = try? await APIClient.shared.getAccountProfile(),
                  response.code == 0,
                  self.account === account,
                  response.data.auth0_id == account.userID else {
                // The GET failed (or raced an account switch). If the cached
                // profile still matches this account, refresh the avatar from
                // it so a reachable avatar host still yields fresh bytes.
                if self.account === account, let picture = cachedProfile?.picture {
                    refreshAvatar(for: account, pictureURLString: picture)
                }
                return
            }
            account.userDefaults.set(
                response.data,
                forCodableKey: key,
                ifCurrentDataEquals: cachedDataAtStart
            )
            refreshAvatar(for: account, pictureURLString: response.data.picture)
        }
    }

    // MARK: Avatar bytes for the Chromium settings bridge

    /// In-memory PNG bytes of the current account's avatar, answered
    /// synchronously to the Chromium settings bridge. An owned copy by
    /// design: the account settings pane force-refreshes the Kingfisher
    /// cache, so that cache is not a stable source for the bridge. Owner
    /// tagged so bytes fetched for a previous account are never served
    /// after an account switch. Main-thread confined (Kingfisher completes
    /// on main; the bridge queries on the UI thread).
    private var avatarPNG: Data?
    private var avatarPNGOwnerID: String?
    /// Bumped on every editor-supplied save. The avatar URL is stable
    /// while its content changes (and Kingfisher attaches same-URL
    /// retrieves to an already in-flight download), so URL refreshes that
    /// started before a local save could otherwise land afterwards and
    /// overwrite the newer image; fetch results only commit when their
    /// starting generation is still current.
    private var avatarGeneration = 0

    /// The current account's avatar PNG bytes, or nil when none have been
    /// fetched yet or the stored bytes belong to a different account.
    func avatarPNG(for account: Account) -> Data? {
        guard avatarPNGOwnerID == account.userID else { return nil }
        return avatarPNG
    }

    /// Stores a locally supplied avatar image (the avatar editor's save
    /// payload) as the bridge answer for `account`.
    func storeAvatarImage(_ image: NSImage, for account: Account) {
        guard self.account === account, let png = image.pngData() else { return }
        avatarPNG = png
        avatarPNGOwnerID = account.userID
        avatarGeneration += 1
    }

    /// Stores fetched bytes unless a newer locally saved avatar landed
    /// while the fetch was in flight.
    private func storeFetchedAvatarImage(
        _ image: NSImage, for account: Account, generation: Int
    ) {
        guard avatarGeneration == generation,
              self.account === account,
              let png = image.pngData() else { return }
        avatarPNG = png
        avatarPNGOwnerID = account.userID
    }

    /// Fills the avatar store from Kingfisher's disk cache (no network).
    /// Hops to the main thread; the passed generation rides along
    /// untouched — refreshAvatar's failure fallback must keep its
    /// original capture, never re-read a fresher one.
    private func warmAvatarFromCache(url: URL, for account: Account, generation: Int) {
        DispatchQueue.main.async {
            KingfisherManager.shared.retrieveImage(with: url, options: [.onlyFromCache]) { cached in
                if case .success(let value) = cached {
                    self.storeFetchedAvatarImage(value.image, for: account, generation: generation)
                }
            }
        }
    }

    /// Fetches the avatar behind `pictureURLString` into the in-memory
    /// store. The URL is stable while its content changes, so the fetch
    /// bypasses the cache (same reason the account settings pane
    /// revalidates with .forceRefresh); on network failure it falls back
    /// to Kingfisher's disk cache so an offline launch still has bytes.
    func refreshAvatar(for account: Account, pictureURLString: String) {
        guard !pictureURLString.isEmpty, let url = URL(string: pictureURLString) else { return }
        // Callers may be off the main thread (prefetchProfile's Task);
        // hop before capturing the generation so the capture and the
        // eventual store are both main-confined.
        DispatchQueue.main.async {
            let generation = self.avatarGeneration
            KingfisherManager.shared.retrieveImage(with: url, options: [.forceRefresh]) { result in
                switch result {
                case .success(let value):
                    self.storeFetchedAvatarImage(value.image, for: account, generation: generation)
                case .failure:
                    self.warmAvatarFromCache(url: url, for: account, generation: generation)
                }
            }
        }
    }

    static var defaultAccount: Account = Account.defaultAccount
}

extension Notification.Name {
    static let mainAccountChanged = Notification.Name("mainAccountDidChange")
}
