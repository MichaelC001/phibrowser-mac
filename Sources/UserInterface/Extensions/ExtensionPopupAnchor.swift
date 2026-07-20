// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Helpers for computing the anchor geometry passed to Chromium when
/// triggering an extension's action popup or context menu.
///
/// The popup trigger hands Chromium the clicked icon's screen rect via
/// `triggerExtension(withId:anchorRect:windowId:)` (below); upstream bubble
/// placement then aligns the popup's right edge to the rect's right edge,
/// expands below it, and mirrors or slides it back onscreen as needed. The
/// point helpers remain for context menus and for the legacy point-based
/// selector of an older framework.
@MainActor
enum ExtensionPopupAnchor {
    /// Returns `view`'s visual bottom-left corner in Chromium screen
    /// coordinates (top-left origin). Returns `nil` if `view` is not
    /// attached to a window.
    static func pointBelowView(_ view: NSView) -> NSPoint? {
        pointBelowRect(view.bounds, in: view)
    }

    /// Same as `pointBelowView`, for a sub-rect of `view`.
    static func pointBelowRect(_ rect: NSRect, in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        let rectInWindow = view.convert(rect, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        // `rectInScreen` is in AppKit's bottom-left-origin screen space, so
        // `minY` is the visual bottom edge.
        return chromiumScreenPoint(from: NSPoint(x: rectInScreen.minX, y: rectInScreen.minY))
    }

    /// Returns `view`'s bounds in Chromium screen coordinates (top-left
    /// origin). Returns `nil` if `view` is not attached to a window.
    static func rectOfView(_ view: NSView) -> NSRect? {
        rectOfRect(view.bounds, in: view)
    }

    /// Same as `rectOfView`, for a sub-rect of `view` — serves surfaces
    /// whose buttons are drawn by SwiftUI and have no NSView of their own
    /// (the content header's reorder surface).
    static func rectOfRect(_ rect: NSRect, in view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        let rectInWindow = view.convert(rect, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        return chromiumScreenRect(from: rectInScreen)
    }

    /// Returns the current mouse location in Chromium screen coordinates
    /// (top-left origin). Used as a defensive fallback when a view-based
    /// anchor is not yet available.
    static func mouseFallback() -> NSPoint {
        chromiumScreenPoint(from: NSEvent.mouseLocation)
    }

    /// Flips an AppKit (bottom-left-origin) screen point to Chromium's
    /// top-left-origin convention using the primary display, which matches
    /// Chromium's `screen_mac.mm` conversion logic.
    static func chromiumScreenPoint(
        from point: NSPoint,
        primaryScreenFrame: NSRect? = NSScreen.screens.first?.frame
    ) -> NSPoint {
        let screenHeight = primaryScreenFrame?.height ?? 0
        return NSPoint(x: point.x, y: screenHeight - point.y)
    }

    /// Flips an AppKit (bottom-left-origin) screen rect to Chromium's
    /// top-left-origin convention using the primary display: the rect's top
    /// edge (AppKit `maxY`) becomes the Chromium origin's y.
    static func chromiumScreenRect(
        from rect: NSRect,
        primaryScreenFrame: NSRect? = NSScreen.screens.first?.frame
    ) -> NSRect {
        let screenHeight = primaryScreenFrame?.height ?? 0
        return NSRect(x: rect.minX,
                      y: screenHeight - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    /// The legacy anchor point (the icon's visual bottom-left corner) for a
    /// rect produced by `chromiumScreenRect` — exactly what `pointBelowView`
    /// returns for the same view. Feeds the point-based bridge selector when
    /// the loaded framework predates the rect-based one.
    static func legacyAnchorPoint(for rect: NSRect) -> NSPoint {
        NSPoint(x: rect.minX, y: rect.maxY)
    }
}

extension PhiChromiumBridgeProtocol {
    /// Triggers an extension's action popup anchored to the clicked icon's
    /// rect (Chromium screen coordinates, from `ExtensionPopupAnchor`). An
    /// older framework without the rect selector falls back to the legacy
    /// point selector at the icon's bottom-left corner; a `nil` rect (view
    /// not in a window) falls back to the mouse location.
    @MainActor
    func triggerExtension(withId extensionId: String, anchorRect: NSRect?, windowId: Int64) {
        if let anchorRect,
           responds(to: #selector(PhiChromiumBridgeProtocol.triggerExtension(withId:rectInScreen:windowId:))) {
            triggerExtension(withId: extensionId, rectInScreen: anchorRect, windowId: windowId)
        } else {
            let point = anchorRect.map(ExtensionPopupAnchor.legacyAnchorPoint(for:))
                ?? ExtensionPopupAnchor.mouseFallback()
            triggerExtension(withId: extensionId, pointInScreen: point, windowId: windowId)
        }
    }
}
