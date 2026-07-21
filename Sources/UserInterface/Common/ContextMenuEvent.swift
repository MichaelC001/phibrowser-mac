// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

enum ContextMenuEvent {
    static func isMouseDown(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown || isControlClick(event)
    }

    static func isControlClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .leftMouseDown
            && event.modifierFlags.contains(.control)
    }
}
