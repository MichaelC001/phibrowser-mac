// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Whole-group drag in comfortable layout used to paint a stray light
/// rectangle at the leading edge of the strip's normal container.
///
/// Temp-collapsing the dragged group lays every member out at `.zero`, and
/// `TabBackgroundLayer` used to keep the path it had built at the member's
/// measured size. A `.zero` frame sits at the container's origin, so the
/// leftover drawing always landed at the strip's leading edge no matter where
/// the group actually sat. Drag ticks restore member `alphaValue` to 1
/// (`TabStrip.setSourceGroupVisualsHidden(false)`), which uncovered it.
///
/// Every collapsed member carried a stale path, but only one could be *seen*:
/// `TabBackgroundLayer` fills clear for `.inactive`, so the visible overlay
/// needed a member carrying the active state. Hence the trigger is "the
/// dragged group holds the active tab" — the strip having no other tabs is
/// one way to force that, not a requirement.
///
/// The cell-level rule this rests on lives in `TabItemViewCollapsedLayoutTests`.
@MainActor
final class TabStripGroupDragStalePaintTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// The group is the strip's only content, so its member is necessarily the
    /// active tab — the shape the artifact was first reported in.
    func test_draggingSoleGroup_leavesNoPaintedCollapsedMember() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, specs: [(guid: 100, token: "G")])
        state.focuseTab(tabs[0])

        let strip = try makeMountedStrip(state: state)

        let member = try XCTUnwrap(descendants(of: strip, as: TabItemView.self).first)
        XCTAssertFalse(member.bounds.isEmpty, "Precondition: member laid out before drag")

        try dragGroupChip(in: strip)
        assertCollapsedMembersPaintNothing(in: strip)
    }

    /// The trigger is not "the group is the strip's only content" — it is "the
    /// dragged group holds the active tab". Same group sitting between ordinary
    /// tabs, active tab inside it, and the stray paint still landed at the
    /// strip's leading edge.
    func test_draggingGroupHoldingActiveTab_amongOtherTabs_leavesNoPaintedCollapsedMember() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, specs: [
            (guid: 200, token: nil),
            (guid: 100, token: "G"),
            (guid: 101, token: "G"),
            (guid: 300, token: nil),
        ])
        // Active tab is a group member, and the group is NOT at index 0.
        state.focuseTab(tabs[1])

        let strip = try makeMountedStrip(state: state)
        let laidOutBeforeDrag = descendants(of: strip, as: TabItemView.self)
            .filter { !$0.bounds.isEmpty }
        XCTAssertEqual(laidOutBeforeDrag.count, 4,
                       "Precondition: all four tabs laid out before the drag")

        try dragGroupChip(in: strip)
        assertCollapsedMembersPaintNothing(in: strip)

        // Anti-regression: dropping the collapsed members' paths may not blank
        // out the tabs that are still in the flow.
        for view in descendants(of: strip, as: TabItemView.self) where !view.bounds.isEmpty {
            guard let background = backgroundLayer(of: view) else { continue }
            XCTAssertFalse(paintedBox(background).isEmpty,
                           "Tab still in the flow \(view.identifierForDiagnostics) stopped painting")
        }
    }

    // MARK: - Drag driver + shared assertion

    /// Grabs the group's chip and drags it right, staying inside the strip so
    /// the drop action resolves to `.local` — the in-strip transform path that
    /// restores member alpha on every tick.
    private func dragGroupChip(in strip: TabStrip) throws {
        let chip = try XCTUnwrap(descendants(of: strip, as: TabGroupChipView.self).first,
                                 "the group's chip should be on the strip")
        let grab = chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        chip.onDragStart?(chip.token, grab)
        strip.layoutSubtreeIfNeeded()
        chip.onDrag?(chip.token, CGPoint(x: grab.x + 60, y: grab.y))
        strip.layoutSubtreeIfNeeded()
        chip.onDrag?(chip.token, CGPoint(x: grab.x + 90, y: grab.y))
    }

    /// The temp-collapse takes every member out of the flow, and nothing out of
    /// the flow may paint.
    ///
    /// The opaque-fill precondition is what ties this to the reported symptom:
    /// a member filling clear could never have been seen, so a run that only
    /// cleared those would prove nothing. Requiring exactly one opaquely-filled
    /// collapsed member asserts the *visible* overlay is the case under test.
    private func assertCollapsedMembersPaintNothing(in strip: TabStrip,
                                                    file: StaticString = #filePath,
                                                    line: UInt = #line) {
        let collapsed = descendants(of: strip, as: TabItemView.self)
            .filter { $0.bounds.isEmpty }
        XCTAssertFalse(collapsed.isEmpty,
                       "Precondition: the drag should have collapsed the group's members",
                       file: file, line: line)

        let opaquelyFilled = collapsed.filter { fillAlpha(of: $0) > 0.01 }
        XCTAssertEqual(opaquelyFilled.count, 1,
                       "Precondition: exactly the active member should carry an opaque fill — "
                       + "collapsed fills were \(collapsed.map { fillAlpha(of: $0) })",
                       file: file, line: line)

        for view in collapsed {
            guard let background = backgroundLayer(of: view) else { continue }
            let painted = paintedBox(background)
            XCTAssertTrue(painted.isEmpty,
                          "Collapsed member \(view.identifierForDiagnostics) painted \(painted) "
                          + "(at \(strip.convert(painted, from: view)) in the strip) "
                          + "at alpha \(view.alphaValue), fill alpha \(fillAlpha(of: view)), "
                          + "while laid out at zero size",
                          file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeBrowserState() throws -> BrowserState {
        let directory = try makeTemporaryStoreDirectory()
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    /// Seeds `specs` in strip order; every distinct non-nil token becomes one
    /// expanded group over its contiguous members.
    @discardableResult
    private func seed(state: BrowserState, specs: [(guid: Int, token: String?)]) -> [Tab] {
        let tabs = specs.enumerated().map { index, spec in
            Tab(guid: spec.guid,
                url: "https://example.com/\(spec.guid)",
                isActive: false,
                index: index)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        for token in Set(specs.compactMap { $0.token }) {
            state.handleTabGroupCreated(token: token,
                                        title: "",
                                        color: .grey,
                                        isCollapsed: false,
                                        initialTabIds: specs.filter { $0.token == token }
                                            .map { $0.guid })
        }
        return tabs
    }

    /// Mounts a strip in a real window (the drag path converts through
    /// window/screen coordinates) and pumps the run loop until the strip's
    /// Combine bindings have delivered the seeded tabs.
    private func makeMountedStrip(state: BrowserState) throws -> TabStrip {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 200),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let content = try XCTUnwrap(window.contentView)

        let strip = TabStrip(browserState: state)
        strip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 100),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -100),
            strip.topAnchor.constraint(equalTo: content.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: TabStripMetrics.Strip.height),
        ])
        strip.setActive(true)

        let expectedTabs = state.normalTabs.count
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              descendants(of: strip, as: TabGroupChipView.self).isEmpty
                || descendants(of: strip, as: TabItemView.self)
                    .filter({ !$0.bounds.isEmpty }).count < expectedTabs {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            content.layoutSubtreeIfNeeded()
        }
        content.layoutSubtreeIfNeeded()
        return strip
    }

    // MARK: - Helpers

    private func backgroundLayer(of view: TabItemView) -> TabBackgroundLayer? {
        view.layer?.sublayers?.compactMap { $0 as? TabBackgroundLayer }.first
    }

    /// Opacity of the cell's fill. Zero means the cell could not have been seen
    /// even with a stale path — `TabBackgroundLayer` fills clear for `.inactive`.
    private func fillAlpha(of view: TabItemView) -> CGFloat {
        backgroundLayer(of: view)?.fillColor?.alpha ?? 0
    }

    /// Bounding box of what the layer actually draws. An absent path and an
    /// empty path both mean "paints nothing".
    private func paintedBox(_ layer: TabBackgroundLayer) -> CGRect {
        guard let path = layer.path else { return .zero }
        let box = path.boundingBoxOfPath
        return box.isNull || box.isInfinite ? .zero : box
    }

    private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        var found: [T] = []
        for subview in root.subviews {
            if let match = subview as? T { found.append(match) }
            found.append(contentsOf: descendants(of: subview, as: type))
        }
        return found
    }
}

private extension NSView {
    var identifierForDiagnostics: String {
        "\(Swift.type(of: self))@\(frame)"
    }
}
