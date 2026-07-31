// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Removes all of Phi's on-disk data for the current product: the Chromium
/// user data root (which also holds the Mac-side `Phi/` subtree), the
/// same-named caches directory, the app preferences plist, and — when the
/// targets say so — the product's Time Machine upgrade-snapshot root.
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
/// 3. **Startup takeover**: the next launch checks for an unfinished
///    removal in `main()` before Chromium reads any state — it stops a
///    still-running cleaner (instead of letting it delete the fresh
///    instance's state), clears canonical-path residue the cleaner never
///    got to, and sweeps leftover `.phi-deleting-` directories.
///
/// The app-group shared container (`group.com.phibrowser.shared`) is
/// deliberately untouched: every file in it is runtime machinery shared
/// with the Sentinel side process (`SharedTokenLock` lock files,
/// `SharedHeartbeatStore` heartbeats, `SharedAuth0Config` client-config
/// mirrors, `SharedAppLanguagePreferenceStore` language state, Sentinel
/// runtime-info markers), and account credentials live in the keychain,
/// cleared separately by `AuthManager`.
enum UserDataRemoval {
    /// The on-disk locations the mechanism erases. Injected so tests can
    /// point the mechanism at a throwaway tree; production uses
    /// `.currentProduct` (debug menu) or `.currentProductIncludingTimeMachine`
    /// (account deletion), which resolve the runtime bundle identifier and
    /// therefore keep canary and release in their own directories.
    struct Targets {
        let dataRootURL: URL
        let cachesURL: URL
        let preferencesPlistURL: URL
        let preferencesDomain: String

        /// The product's Time Machine upgrade-snapshot root
        /// (`…/Application Support/com.phibrowser.TimeMachine/<bundleId>`),
        /// which holds copies of the Phi data subtree and the preferences
        /// plist. Nil keeps it: the snapshots are the upgrade safety net,
        /// so the debug menu's clear leaves them alone; the account
        /// deletion, which promises a machine with no Phi traces, removes
        /// them. Each channel has its own subtree, so removal never
        /// crosses into the sibling product's snapshots.
        let timeMachineRootURL: URL?

        init(
            dataRootURL: URL,
            cachesURL: URL,
            preferencesPlistURL: URL,
            preferencesDomain: String,
            timeMachineRootURL: URL? = nil
        ) {
            self.dataRootURL = dataRootURL
            self.cachesURL = cachesURL
            self.preferencesPlistURL = preferencesPlistURL
            self.preferencesDomain = preferencesDomain
            self.timeMachineRootURL = timeMachineRootURL
        }

        static var currentProduct: Targets {
            productTargets(timeMachineRootURL: nil)
        }

        /// `currentProduct` plus the Time Machine snapshot root: the
        /// account deletion's target set, and what the startup takeover
        /// scans on every launch (see `UserDataRemovalBootstrap`).
        static var currentProductIncludingTimeMachine: Targets {
            productTargets(timeMachineRootURL: TimeMachinePaths.defaultRootURL())
        }

        private static func productTargets(timeMachineRootURL: URL?) -> Targets {
            Targets(
                dataRootURL: URL(fileURLWithPath: FileSystemUtils.applicationSupportDirctory(), isDirectory: true),
                cachesURL: URL(fileURLWithPath: FileSystemUtils.cacheDirctory(), isDirectory: true),
                preferencesPlistURL: URL(fileURLWithPath: FileSystemUtils.plistPath()),
                preferencesDomain: FileSystemUtils.bundleId,
                timeMachineRootURL: timeMachineRootURL
            )
        }

        /// The directories `beginRemoval` moves aside and the startup sweep
        /// scans for `.phi-deleting-` leftovers.
        var moveAsideDirectoryURLs: [URL] {
            [dataRootURL, cachesURL, timeMachineRootURL].compactMap { $0 }
        }

        /// Where the detached cleaner records its subshell PID and start
        /// time. A sibling of the data root — outside all removal
        /// targets, so the removal cannot erase its own marker — with a name
        /// the leftover sweep's `.phi-deleting-` prefix does not match. The
        /// cleaner deletes it as its final act, so its presence means a
        /// cleanup is (or died) in progress.
        var cleanerPIDFileURL: URL {
            dataRootURL.deletingLastPathComponent().appendingPathComponent(
                dataRootURL.lastPathComponent + ".phi-deletion-cleaner.pid"
            )
        }
    }

    /// Inserted between the directory name and a UUID when a directory is
    /// renamed for deletion; the startup sweep matches on it.
    private static let moveAsideMarker = ".phi-deleting-"

    /// Replaces `moveAsideMarker` in a leftover's name when the sweep cannot
    /// delete it. The rename takes the directory out of the marker
    /// namespace: a leftover that stayed both undeletable and a marker
    /// would re-trigger the takeover on every launch — each time deleting
    /// the canonical paths, i.e. the fresh profile the previous session
    /// just created.
    private static let stuckMarker = ".phi-deletion-stuck-"

    /// Runs the in-process half of the removal and spawns the detached
    /// cleaner. Call only on the way into app termination: the canonical
    /// paths are already empty when this returns, the cleaner waits for the
    /// process to exit before finishing the deletion, and any
    /// standard-defaults write from here on would resurrect the dropped
    /// preferences domain. The debug menu quits right after this call; the
    /// account deletion runs its remaining clears in between and re-drops
    /// the domain on its way out (see `AccountDeletionLocalDataRemoval`).
    static func beginRemoval(of targets: Targets) {
        UserDefaults.standard.removePersistentDomain(forName: targets.preferencesDomain)
        let movedAside = moveAsideForDeletion(targets)
        spawnDetachedCleaner(for: targets, movedAside: movedAside)
    }

    /// Renames each targeted directory (data root, caches, and the Time
    /// Machine root when covered) to a sibling `.phi-deleting-` name and
    /// returns the new locations. Missing directories are skipped; a failed
    /// rename is logged and left for the detached cleaner, which deletes
    /// the canonical paths after exit anyway.
    static func moveAsideForDeletion(_ targets: Targets) -> [URL] {
        targets.moveAsideDirectoryURLs.compactMap { url in
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
            // The moved-aside directories stay behind; the startup takeover
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
    /// state deleted along with the residue — unless that instance's
    /// startup takeover (`takeOverPendingRemovalIfNeeded`) stops the
    /// cleaner first, which is exactly what the PID file below is for.
    ///
    /// The outer shell writes the backgrounded subshell's PID and start
    /// time to the PID file (only the outer shell knows that PID); the
    /// start time lets the next launch tell the cleaner apart from a
    /// recycled PID. The subshell removes the file as its final act, so
    /// the file's lifetime spans the whole cleanup.
    static func detachedCleanerScript(
        for targets: Targets,
        movedAside: [URL],
        mainProcessID: Int32
    ) -> String {
        let canonicalPassArgs = (targets.moveAsideDirectoryURLs + [targets.preferencesPlistURL])
            .map { shellSingleQuoted($0.path) }
            .joined(separator: " ")
        let pidFile = shellSingleQuoted(targets.cleanerPIDFileURL.path)
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
           "  /bin/rm -rf -- \(canonicalPassArgs)",
           "  /bin/rm -f -- \(pidFile) ) >/dev/null 2>&1 &",
           "echo $! > \(pidFile)",
           "/bin/ps -o lstart= -p $! >> \(pidFile) 2>/dev/null"]
        return lines.joined(separator: "\n")
    }

    /// The startup takeover's sweep: removes leftover moved-aside
    /// directories in case the detached cleaner was killed before it ran.
    /// Only `.phi-deleting-` names are touched, so this is safe to run
    /// while the app is using the canonical directories.
    static func sweepLeftoverMoveAsideDirectories(for targets: Targets) {
        for leftover in leftoverMoveAsideDirectories(for: targets) {
            do {
                try FileManager.default.removeItem(at: leftover)
                AppLogInfo("[UserDataRemoval] Swept leftover \(leftover.path)")
            } catch {
                AppLogWarn("[UserDataRemoval] Failed to sweep leftover \(leftover.path): \(error.localizedDescription)")
                parkUndeletableLeftover(leftover)
            }
        }
    }

    /// A leftover that cannot be deleted must at least stop being a
    /// takeover marker (see `stuckMarker`). Renaming is metadata-only, so
    /// it succeeds under most conditions that make a recursive delete fail
    /// (an immutable or unreadable entry deep inside the tree). The parked
    /// directory stays behind as an inert, unreferenced copy — the failure
    /// direction the mechanism already accepts — and the log points at it.
    private static func parkUndeletableLeftover(_ leftover: URL) {
        let parkedName = leftover.lastPathComponent.replacingOccurrences(
            of: moveAsideMarker,
            with: stuckMarker
        )
        let destination = leftover.deletingLastPathComponent()
            .appendingPathComponent(parkedName, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: leftover, to: destination)
            AppLogWarn("[UserDataRemoval] Parked undeletable leftover at \(destination.path)")
        } catch {
            AppLogWarn("[UserDataRemoval] Failed to park leftover \(leftover.path): \(error.localizedDescription)")
        }
    }

    private static func leftoverMoveAsideDirectories(for targets: Targets) -> [URL] {
        let fm = FileManager.default
        return targets.moveAsideDirectoryURLs.flatMap { canonical -> [URL] in
            let parent = canonical.deletingLastPathComponent()
            let leftoverPrefix = canonical.lastPathComponent + moveAsideMarker
            guard let siblings = try? fm.contentsOfDirectory(atPath: parent.path) else { return [] }
            return siblings.filter { $0.hasPrefix(leftoverPrefix) }
                .map { parent.appendingPathComponent($0) }
        }
    }

    // MARK: - Startup takeover

    /// Finishes an interrupted removal at launch, before Chromium reads any
    /// state. Two signals mark one, and either suffices:
    /// - the cleaner PID file answers "is a cleaner still running that must
    ///   be stopped" — it exists for the cleaner's whole lifetime;
    /// - leftover moved-aside directories answer "is there work to take
    ///   over" — they also cover rename-succeeded-but-spawn-failed, where
    ///   no PID file was ever written.
    ///
    /// With either present, the takeover stops a live cleaner (so it cannot
    /// delete this instance's fresh first-run state), then finishes the job
    /// itself: preferences domain, canonical-path residue (the shutdown
    /// rewrites the cleaner never got to sweep — `Local State`,
    /// `Default/Preferences`, the plist, ...), pending Time Machine
    /// restores, leftover directories, and finally the PID file. With
    /// neither signal this is a no-op. When both rename and spawn failed
    /// there is no signal either — but then nothing was moved and no
    /// removal took effect, so there is no residue to finish.
    static func takeOverPendingRemovalIfNeeded(for targets: Targets) {
        let fm = FileManager.default
        let leftovers = leftoverMoveAsideDirectories(for: targets)
        let pidFileContents = try? String(contentsOf: targets.cleanerPIDFileURL, encoding: .utf8)
        guard pidFileContents != nil || !leftovers.isEmpty else { return }

        AppLogInfo("[UserDataRemoval] Unfinished removal detected; taking over")
        if let pidFileContents {
            stopLiveCleaner(recordedIn: pidFileContents)
        }

        UserDefaults.standard.removePersistentDomain(forName: targets.preferencesDomain)
        // The Time Machine root is deliberately not a residue target here:
        // nothing rewrites it during shutdown, so canonical content at this
        // point is a live root — after an interrupted debug-menu clear that
        // is the user's snapshot store, which that flow's scope keeps. The
        // account deletion moves the root aside with the others; should
        // that rename have failed, the surviving root is the accepted
        // rare-residue direction, with restore resurrection prevented by
        // the cancellation below.
        for url in [targets.dataRootURL, targets.cachesURL, targets.preferencesPlistURL]
        where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                AppLogInfo("[UserDataRemoval] Removed canonical residue \(url.path)")
            } catch {
                AppLogWarn("[UserDataRemoval] Failed to remove canonical residue \(url.path): \(error.localizedDescription)")
            }
        }
        if let timeMachineRootURL = targets.timeMachineRootURL {
            cancelPendingTimeMachineRestores(underRoot: timeMachineRootURL)
        }
        sweepLeftoverMoveAsideDirectories(for: targets)
        try? fm.removeItem(at: targets.cleanerPIDFileURL)
    }

    /// An unfinished removal outranks a pending Time Machine restore: the
    /// startup order is takeover → restore recovery, so a restore recovered
    /// right after this hook would resurrect the very data the removal
    /// erased. Cancelling removes each pending operation directory that
    /// carries a restore journal — journal and artifacts together, because
    /// every Time Machine cleanup path is keyed on the journal, so a
    /// directory stripped of just its journal would linger invisibly
    /// forever with its downloaded package and staged app. The operation
    /// directory holds only reproducible artifacts; the emergency backups
    /// of the user's own data live under Emergency/, untouched — as do the
    /// snapshots and catalog, which an interrupted debug-menu clear (whose
    /// scope excludes Time Machine) must keep. Journal-less directories
    /// are left alone: the recovery gate cannot see them, so there is
    /// nothing to cancel. The check is file existence, not journal
    /// decodability — cancelling must keep working when the journal is
    /// corrupt. On the account-deletion path the whole root normally left
    /// the canonical location with the move-aside; this covers the corner
    /// where that rename failed.
    private static func cancelPendingTimeMachineRestores(underRoot rootURL: URL) {
        let fm = FileManager.default
        let pendingRootURL = rootURL.appendingPathComponent(
            TimeMachinePaths.pendingDirectoryName, isDirectory: true
        )
        guard let operationNames = try? fm.contentsOfDirectory(atPath: pendingRootURL.path) else {
            return
        }
        for name in operationNames {
            let operationURL = pendingRootURL.appendingPathComponent(name, isDirectory: true)
            let journalURL = operationURL.appendingPathComponent(
                TimeMachinePaths.journalFilename, isDirectory: false
            )
            guard fm.fileExists(atPath: journalURL.path) else { continue }
            do {
                try fm.removeItem(at: operationURL)
                AppLogInfo("[UserDataRemoval] Cancelled pending Time Machine restore \(name)")
            } catch {
                AppLogWarn("[UserDataRemoval] Failed to cancel pending Time Machine restore \(name): \(error.localizedDescription)")
                // Deleting the journal alone still seals the restore; the
                // stranded artifacts are the accepted residue then.
                try? fm.removeItem(at: journalURL)
            }
        }
    }

    /// Parses "<pid>\n<lstart>" as the spawn script writes it. Both lines
    /// are required: without the start time a recycled PID could not be
    /// told apart from the cleaner, so the caller skips the kill and goes
    /// straight to deleting.
    static func parseCleanerPIDFile(_ contents: String) -> (pid: Int32, startedAt: String)? {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let pid = Int32(lines[0]), pid > 0, !lines[1].isEmpty else {
            return nil
        }
        return (pid, lines[1])
    }

    private static func stopLiveCleaner(recordedIn contents: String) {
        guard let record = parseCleanerPIDFile(contents) else {
            AppLogWarn("[UserDataRemoval] Unreadable cleaner PID file; skipping the kill")
            return
        }
        guard let liveStart = processStartTime(of: record.pid), liveStart == record.startedAt else {
            // Not running any more, or the PID now belongs to some other
            // process — either way there is nothing of ours to stop.
            return
        }
        kill(record.pid, SIGKILL)
        AppLogInfo("[UserDataRemoval] Stopped the live cleaner (pid \(record.pid))")
        // The kill hits the cleaner's subshell; an `rm` child that was
        // mid-flight survives as an orphan and finishes its current pass.
        // The canonical passes are millisecond-scale (skeleton files), so
        // a short drain keeps them from interleaving with this instance's
        // deletions and first writes.
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// `ps`'s lstart for the process, nil when it is not running. Matching
    /// it against the recorded value is an attribute check on a known PID
    /// (not a find-by-name search): equal strings mean this is still the
    /// very process the spawn script recorded.
    private static func processStartTime(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "lstart=", "-p", String(pid)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else { return nil }
        return output
    }

    private static func shellSingleQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The `main()`-time entry point for the takeover, callable from
/// Objective-C before Chromium initializes (mirrors `TimeMachineBootstrap`).
@objc(UserDataRemovalBootstrap)
final class UserDataRemovalBootstrap: NSObject {
    @objc static func takeOverPendingRemovalIfNeeded() {
        // Time Machine included: the takeover must sweep the account
        // deletion's moved-aside Time Machine root and cancel pending
        // restores before the recovery gate runs. For an interrupted
        // debug-menu clear this adds nothing destructive — that flow never
        // moves the root aside, and cancellation touches journal files
        // only.
        UserDataRemoval.takeOverPendingRemovalIfNeeded(for: .currentProductIncludingTimeMachine)
    }
}
