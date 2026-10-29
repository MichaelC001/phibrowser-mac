// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class EventBlockBgView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
    }
    
    var mouseDown: ((NSEvent) -> Void)?

    /// When set, the overlay owns only the returned view (and its subviews):
    /// a hit anywhere else answers nil, so the click falls through to whatever
    /// sits beneath this view in the same window instead of being swallowed
    /// (and `mouseDown` is never invoked for it). nil keeps the overlay modal.
    var clickThroughOutside: (() -> NSView?)?

    /// Called once per mouse-down that fell through `clickThroughOutside`,
    /// before the click reaches the view beneath. Callers that dismiss the
    /// overlay must do so on a later turn: the click is still being hit-tested.
    var clickedThroughOutside: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let keep = clickThroughOutside?() else { return hit }
        var view = hit
        while let current = view {
            if current === keep { return hit }
            view = current.superview
        }
        // Hit testing also runs for hover and cursor updates; only a press
        // counts as a click outside.
        if let type = NSApp.currentEvent?.type,
           type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            clickedThroughOutside?()
        }
        return nil
    }

    // Transparent but intercepts events
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        mouseDown?(event)
        super.mouseDown(with: event)
    }
    
    override func mouseMoved(with event: NSEvent) {
        
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }
    
    override func rightMouseDown(with event: NSEvent) {
        
    }
    
    override func rightMouseUp(with event: NSEvent) {
        
    }
    
    // Swallow hit-testing so A never receives click/hover when B is visible
//    override func hitTest(_ point: NSPoint) -> NSView? {
//        let p = convert(point, from: superview)
//        return bounds.contains(p) ? self : nil
//    }
//
//    // Force arrow cursor over the whole overlay (preempts A's cursor)
//    override func resetCursorRects() {
//        super.resetCursorRects()
//        discardCursorRects()
//        addCursorRect(bounds, cursor: .arrow)
//    }
}
