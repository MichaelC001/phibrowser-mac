// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/*
Temporarily disabled: a dedicated CDP session for every tab may add overhead.
Keep the implementation for future evaluation; Tab no longer installs this guard.
 */


/// Keeps a Shift-click's native Peek action from also reaching a site's SPA
/// router. Chromium handles the link's default action after page listeners,
/// so its existing Peek routing alone cannot prevent those listeners navigating
/// the opener. Use the same app-owned document-script transport as AgentPageTheme.
//@MainActor
//final class PeekLinkActivationGuard {
//    private let targetId: String
//    private var session: AppDevToolsPageSession?
//    private var scriptIdentifier: String?
//    private var requestedEnabled: Bool?
//    private var updateTask: Task<Void, Never>?
//    private var preferences: AnyCancellable?
//
//    init?(wrapper: WebContentWrapper & NSObject) {
//        guard wrapper.responds(to: #selector(getter: WebContentWrapper.devToolsTargetId)),
//              let targetId = wrapper.devToolsTargetId, !targetId.isEmpty else {
//            AppLogWarn("[Peek] link activation guard has no page target")
//            return nil
//        }
//        self.targetId = targetId
//        preferences = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
//            .receive(on: DispatchQueue.main)
//            .sink { [weak self] _ in self?.refresh() }
//        refresh()
//    }
//
//    private func refresh() {
//        let enabled = PhiPreferences.GeneralSettings.peekViewEnabled.loadValue()
//            && !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
//        guard requestedEnabled != enabled else { return }
//        requestedEnabled = enabled
//        let previous = updateTask
//        // The CDP transport is single-flight. Serialize preference changes,
//        // including a disable while the initial connection is still opening.
//        updateTask = Task { @MainActor [weak self] in
//            await previous?.value
//            guard let self, let enabled = self.requestedEnabled else { return }
//            await self.apply(enabled: enabled)
//        }
//    }
//
//    /// Pause videos in the opener's existing frames, including silent videos
//    /// that never establish a native MediaSession. Nothing resumes them on close.
//    func pauseVideos() {
//        let previous = updateTask
//        updateTask = Task { @MainActor [weak self] in
//            await previous?.value
//            guard let self, let session = self.session else { return }
//            do {
//                let added = try await session.command("Page.addScriptToEvaluateOnNewDocument", params: [
//                    "source": Self.pauseVideosScript,
//                    "runImmediately": true,
//                ])
//                if let identifier = added["identifier"] as? String {
//                    _ = try await session.command("Page.removeScriptToEvaluateOnNewDocument",
//                                                   params: ["identifier": identifier])
//                }
//                _ = try await session.command("Runtime.evaluate", params: [
//                    "expression": Self.pauseVideosScript,
//                    "returnByValue": true,
//                ])
//            } catch {
//                AppLogWarn("[Peek] opener video pause failed: \(error)")
//            }
//        }
//    }
//
//    private func apply(enabled: Bool) async {
//        if enabled {
//            guard scriptIdentifier == nil else { return }
//            do {
//                let connection = try await AppDevToolsPageSession.open(targetId: targetId)
//                session = connection
//                _ = try await connection.command("Page.enable")
//                let added = try await connection.command("Page.addScriptToEvaluateOnNewDocument", params: [
//                    "source": Self.activationScript,
//                    "runImmediately": true,
//                ])
//                scriptIdentifier = added["identifier"] as? String
//                _ = try await connection.command("Runtime.evaluate", params: [
//                    "expression": Self.activationScript,
//                    "returnByValue": true,
//                ])
//                AppLogDebug("[Peek] link activation guard installed for target=\(targetId)")
//            } catch {
//                session?.close()
//                session = nil
//                requestedEnabled = nil
//                AppLogWarn("[Peek] link activation guard unavailable: \(error)")
//            }
//        } else if let session {
//            await Self.remove(from: session, scriptIdentifier: scriptIdentifier)
//            self.session = nil
//            scriptIdentifier = nil
//        }
//    }
//
//    private static func remove(from session: AppDevToolsPageSession, scriptIdentifier: String?) async {
//        if let scriptIdentifier {
//            _ = try? await session.command("Page.removeScriptToEvaluateOnNewDocument",
//                                           params: ["identifier": scriptIdentifier])
//        }
//        // runImmediately covers child frames too, including cross-origin ones.
//        let cleanup = try? await session.command("Page.addScriptToEvaluateOnNewDocument", params: [
//            "source": removalScript,
//            "runImmediately": true,
//        ])
//        if let identifier = cleanup?["identifier"] as? String {
//            _ = try? await session.command("Page.removeScriptToEvaluateOnNewDocument",
//                                           params: ["identifier": identifier])
//        }
//        session.close()
//    }
//
//    /// Stop page listeners without cancelling the anchor's default action:
//    /// Chromium still owns URL resolution, the gesture and native Peek routing.
//    private static let activationScript = """
//    (() => {
//      const key = Symbol.for('phi.peek.linkActivationGuard');
//      if (window[key]) return;
//      const handleClick = event => {
//        if (!event.isTrusted || event.button !== 0 || !event.shiftKey || event.metaKey ||
//            event.ctrlKey || event.altKey || event.defaultPrevented) return;
//        const link = event.composedPath().find(node =>
//          node instanceof Element && node.matches('a[href], area[href]'));
//        if (!link || link.hasAttribute('download') || link.isContentEditable) return;
//        let url;
//        try { url = new URL(link.getAttribute('href'), link.baseURI); } catch { return; }
//        if (url.protocol !== 'https:' && url.protocol !== 'http:') return;
//        event.stopImmediatePropagation();
//        \(pauseVideosScript);
//      };
//      window.addEventListener('click', handleClick, true);
//      window[key] = handleClick;
//    })()
//    """
//
//    private static let pauseVideosScript = """
//    (() => {
//      for (const video of document.querySelectorAll('video')) {
//        if (!video.paused) video.pause();
//      }
//    })()
//    """
//
//    private static let removalScript = """
//    (() => {
//      const key = Symbol.for('phi.peek.linkActivationGuard');
//      if (window[key]) window.removeEventListener('click', window[key], true);
//      delete window[key];
//    })()
//    """
//
//    isolated deinit {
//        updateTask?.cancel()
//        if let session {
//            let identifier = scriptIdentifier
//            Task { await Self.remove(from: session, scriptIdentifier: identifier) }
//        }
//    }
 //}
