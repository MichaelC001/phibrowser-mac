// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Removes all of Phi's on-disk data for the current product: the Chromium
/// user data root (which also holds the Mac-side `Phi/` subtree), the
/// same-named caches directory, and the app preferences plist.
///
/// Deleting the directories in place while Chromium is still running is not
/// enough: a normal shutdown rewrites `Local State`, `Default/Preferences`,
/// and friends onto the canonical path via path-based atomic writes, and
/// cfprefsd caches the whole preferences domain and rewrites the plist after
/// a bare file delete. The mechanism therefore has three phases:
///
/// 1. **Move aside** (in-process, immediately before initiating a normal
///    quit): atomically rename each directory to a sibling
///    `<name>.phi-deleting-<UUID>` directory, and drop the preferences
///    domain from cfprefsd. Open file handles keep writing into the renamed
///    directories, so shutdown stays graceful.
/// 2. **Detached cleanup**: a spawned shell, reparented to launchd, waits
///    for this process to exit, then deletes the moved-aside directories
///    plus whatever the shutdown rewrote at the canonical paths, and
///    re-deletes the canonical paths once more as a backstop.
/// 3. **Startup fallback**: the next launch sweeps leftover
///    `.phi-deleting-` directories in case the cleaner never ran.
///
/// The app-group shared container (`group.com.phibrowser.shared`) is
/// deliberately untouched: every file in it is runtime machinery shared
/// with the Sentinel side process (`SharedTokenLock` lock files,
/// `SharedHeartbeatStore` heartbeats, `SharedAuth0Config` client-config
/// mirrors, Sentinel runtime-info markers), and account credentials live in
/// the keychain, cleared separately by `AuthManager`.
enum UserDataRemoval {
    /// The on-disk locations the mechanism erases. Injected so tests can
    /// point the mechanism at a throwaway tree; production uses
    /// `.currentProduct`, which resolves the runtime bundle identifier and
    /// therefore keeps canary and release in their own directories.
    struct Targets {
        let dataRootURL: URL
        let cachesURL: URL
        let preferencesPlistURL: URL
        let preferencesDomain: String

        static var currentProduct: Targets {
            Targets(
                dataRootURL: URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true),
                cachesURL: URL(fileURLWithPath: FileSystemUtils.cacheDirctory(), isDirectory: true),
                preferencesPlistURL: URL(fileURLWithPath: FileSystemUtils.plistPath()),
                preferencesDomain: FileSystemUtils.bundleId
            )
        }
    }

    /// Inserted between the directory name and a UUID when a directory is
    /// renamed for deletion; the startup sweep matches on it.
    private static let moveAsideMarker = ".phi-deleting-"

    /// Runs the in-process half of the removal and spawns the detached
    /// cleaner. Call immediately before initiating app termination; the
    /// canonical paths are already empty when this returns, and the cleaner
    /// finishes the deletion after the process exits.
    static func beginRemoval(of targets: Targets) {
        UserDefaults.standard.removePersistentDomain(forName: targets.preferencesDomain)
        let movedAside = moveAsideForDeletion(targets)
        spawnDetachedCleaner(for: targets, movedAside: movedAside)
    }

    /// Renames the data root and caches directory to sibling
    /// `.phi-deleting-` names and returns the new locations. Missing
    /// directories are skipped; a failed rename is logged and left for the
    /// detached cleaner, which deletes the canonical paths after exit
    /// anyway.
    static func moveAsideForDeletion(_ targets: Targets) -> [URL] {
        [targets.dataRootURL, targets.cachesURL].compactMap { url in
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return nil }
            let destination = url.deletingLastPathComponent().appendingPathComponent(
                url.lastPathComponent + moveAsideMarker + UUID().uuidString,
                isDirectory: true
            )
            do {
                try fm.moveItem(at: url, to: destination)
                return destination
            } catch {
                AppLogWarn("[UserDataRemoval] Failed to move aside \(url.path): \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Spawns the phase-2 cleaner. `sh` backgrounds a subshell and exits
    /// immediately, so the subshell is reparented to launchd and survives
    /// the app (same pattern as the debug relaunch helper).
    static func spawnDetachedCleaner(
        for targets: Targets,
        movedAside: [URL],
        mainProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            detachedCleanerScript(for: targets, movedAside: movedAside, mainProcessID: mainProcessID)
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The moved-aside directories stay behind; the startup fallback
            // sweeps them on the next launch.
            AppLogWarn("[UserDataRemoval] Failed to spawn detached cleaner: \(error.localizedDescription)")
        }
    }

    /// The cleaner waits for the main process to exit, sleeps past the
    /// straggling crashpad handlers (they outlive the main process by
    /// ~200 ms), deletes everything, and re-deletes the canonical paths a
    /// few seconds later as a backstop against late rewrites.
    ///
    /// The canonical passes run unconditionally: a Phi instance relaunched
    /// within the cleaner's few-second window has its fresh first-run
    /// state deleted along with the residue. That trade is deliberate —
    /// deterministic cleanup over protecting a session that can only hold
    /// seconds-old state, since the user's original data already sits in
    /// the moved-aside directories by that point.
    static func detachedCleanerScript(
        for targets: Targets,
        movedAside: [URL],
        mainProcessID: Int32
    ) -> String {
        let canonicalPassArgs = [targets.dataRootURL, targets.cachesURL, targets.preferencesPlistURL]
            .map { shellSingleQuoted($0.path) }
            .joined(separator: " ")
        let movedPass: [String] = movedAside.isEmpty ? [] : [
            "  /bin/rm -rf -- " + movedAside.map { shellSingleQuoted($0.path) }.joined(separator: " ")
        ]
        let lines = [
            "( while /bin/kill -0 \(mainProcessID) 2>/dev/null; do sleep 0.2; done",
            "  sleep 2.5"
        ]
        + movedPass
        + ["  /bin/rm -rf -- \(canonicalPassArgs)",
           "  sleep 3",
           "  /bin/rm -rf -- \(canonicalPassArgs) ) >/dev/null 2>&1 &"]
        return lines.joined(separator: "\n")
    }

    /// Phase-3 startup fallback: removes leftover moved-aside directories
    /// in case the detached cleaner was killed before it ran. Only
    /// `.phi-deleting-` names are touched, so this is safe to run while
    /// the app is using the canonical directories.
    static func sweepLeftoverMoveAsideDirectories(for targets: Targets) {
        let fm = FileManager.default
        for canonical in [targets.dataRootURL, targets.cachesURL] {
            let parent = canonical.deletingLastPathComponent()
            let leftoverPrefix = canonical.lastPathComponent + moveAsideMarker
            guard let siblings = try? fm.contentsOfDirectory(atPath: parent.path) else { continue }
            for name in siblings where name.hasPrefix(leftoverPrefix) {
                let leftover = parent.appendingPathComponent(name)
                do {
                    try fm.removeItem(at: leftover)
                    AppLogInfo("[UserDataRemoval] Swept leftover \(leftover.path)")
                } catch {
                    AppLogWarn("[UserDataRemoval] Failed to sweep leftover \(leftover.path): \(error.localizedDescription)")
                }
            }
        }
    }

    private static func shellSingleQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
