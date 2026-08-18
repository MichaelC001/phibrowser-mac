// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Dragging a group that holds the active tab used to paint a small stray
/// four-pointed star straddling the strip's bottom edge, tracking the cursor.
///
/// Measured off the 2026-08-18 recording: a 16x16pt hairline stroked in
/// `ThemedColor.border` (black at 8%), centred on the content's top edge — the
/// content outline's active-tab notch collapsed onto itself. A whole-group drag
/// temp-collapses the group, so every member is laid out at `.zero`, and
/// `TabStrip.tabFrame(for:in:)` still reported that empty cell (offset by the
/// drag delta, which is why the star tracked the cursor). Feeding
/// `leftX == rightX` to `appendActiveTabOutline` folds the two inverse curves
/// and the top corners into a bowtie one `inverseCornerRadius` wide.
///
/// The trigger is "the dragged group holds the active tab", not "the group is
/// the strip's only content" — a sole group just forces that, because its
/// member has to be the active tab. A data-layer collapse can't reach this
/// state: `tab_groups_proxy.cc`'s `SetTabGroupCollapsed` activates another tab
/// (or opens one) before collapsing, so the drag's temp-collapse is the only
/// path that leaves the active tab inside a zero-framed group.
@MainActor
final class TabStripGroupDragActiveTabOutlineTests: XCTestCase {

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
    /// active tab — the shape the artifact was reported in.
    func test_draggingSoleGroup_reportsNoOutlineFrameForTheCollapsedActiveMember() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, specs: [(guid: 100, token: "G")])
        state.focuseTab(tabs[0])

        let strip = try makeMountedStrip(state: state)
        let host = try XCTUnwrap(strip.superview)

        let beforeDrag = try XCTUnwrap(strip.tabFrame(for: tabs[0], in: host),
                                       "Precondition: the member reports its cell before the drag")
        XCTAssertGreaterThanOrEqual(beforeDrag.width, TabStripMetrics.Tab.minWidth,
                                    "Precondition: the pre-drag cell is a real tab")

        try dragGroupChip(in: strip)
        assertPaintsNoStrayNotch(strip.tabFrame(for: tabs[0], in: host), strip: strip)
    }

    /// Same defect with ordinary tabs around the group: the strip having no
    /// other tabs is not what triggers it.
    func test_draggingGroupHoldingActiveTab_amongOtherTabs_reportsNoOutlineFrame() throws {
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
        let host = try XCTUnwrap(strip.superview)

        try dragGroupChip(in: strip)
        assertPaintsNoStrayNotch(strip.tabFrame(for: tabs[1], in: host), strip: strip)
    }

    /// Anti-regression: dropping the collapsed members' frames may not cost the
    /// tabs that stay in the flow their outline. The active tab sits outside
    /// the dragged group here, so the content border must keep carving around
    /// its cell for the whole drag.
    func test_draggingGroupWithoutTheActiveTab_keepsTheActiveTabOutline() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, specs: [
            (guid: 200, token: nil),
            (guid: 100, token: "G"),
            (guid: 101, token: "G"),
            (guid: 300, token: nil),
        ])
        state.focuseTab(tabs[0])

        let strip = try makeMountedStrip(state: state)
        let host = try XCTUnwrap(strip.superview)

        try dragGroupChip(in: strip)

        let during = try XCTUnwrap(strip.tabFrame(for: tabs[0], in: host),
                                   "the active tab is outside the dragged group and stays laid out")
        XCTAssertGreaterThanOrEqual(during.width, TabStripMetrics.Tab.minWidth,
                                    "reported \(during) for a tab that never left the flow")
    }

    // MARK: - Drag driver + shared assertion

    /// Grabs the group's chip and drags it right, staying inside the strip so
    /// the drop action resolves to `.local` — the branch that offsets the
    /// member's frame by the drag delta instead of suppressing it.
    private func dragGroupChip(in strip: TabStrip) throws {
        let chip = try XCTUnwrap(descendants(of: strip, as: TabGroupChipView.self).first,
                                 "the group's chip should be on the strip")
        let grab = chip.convert(CGPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        chip.onDragStart?(chip.token, grab)
        strip.layoutSubtreeIfNeeded()
        chip.onDrag?(chip.token, CGPoint(x: grab.x + 60, y: grab.y))
        strip.layoutSubtreeIfNeeded()
        chip.onDrag?(chip.token, CGPoint(x: grab.x + 90, y: grab.y))
        strip.layoutSubtreeIfNeeded()
        // Guards every case in this class against a vacuous pass: a drag that
        // silently failed to start would leave the members at their real
        // widths, which satisfies the assertions below for the wrong reason.
        XCTAssertTrue(
            descendants(of: strip, as: TabItemView.self).contains { $0.bounds.isEmpty },
            "Precondition: the drag should have temp-collapsed the group's members")
    }

    /// A frame the content border can't carve a tab notch out of must not be
    /// reported at all: `WebContentContainerViewController` has no width test
    /// beyond the strip-edge bounds check, so anything narrower than a tab
    /// reaches `appendActiveTabOutline` and paints as a stray stub.
    ///
    /// Deliberately stronger than the guard under test, which only rejects
    /// empty frames — that suffices because the layout engine's out-of-flow
    /// placeholder is exactly `.zero`, while this states the property that
    /// actually matters: whatever gets reported has to be able to carry a
    /// notch.
    private func assertPaintsNoStrayNotch(_ reported: CGRect?,
                                          strip: TabStrip,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) {
        guard let reported else { return }  // border falls back to its plain closed outline
        XCTAssertGreaterThanOrEqual(
            reported.width, TabStripMetrics.Tab.minWidth,
            "reported \(reported) for a member the drag took out of the flow — the content "
            + "border would paint \(notchBox(for: reported, apexY: strip.frame.minY)) "
            + "instead of a tab notch",
            file: file, line: line)
    }

    /// Bounding box of the active-tab notch the content border builds out of a
    /// reported frame — the same helper `updateContentOuterBorder` feeds. It
    /// passes the content card's top edge as `apexY`; the strip's bottom edge
    /// stands in here, which moves the box's origin but not its size. Feeds
    /// the failure message only.
    private func notchBox(for frame: CGRect, apexY: CGFloat) -> CGRect {
        let path = CGMutablePath()
        TabStripMetrics.appendActiveTabOutline(to: path,
                                               leftX: frame.minX,
                                               rightX: frame.maxX,
                                               apexY: apexY,
                                               tabTopY: frame.maxY)
        let box = path.boundingBoxOfPath
        return box.isNull || box.isInfinite ? .zero : box
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
        return BrowserState(windowId: 8, localStore: store, profileId: "Default")
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

    private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        var found: [T] = []
        for subview in root.subviews {
            if let match = subview as? T { found.append(match) }
            found.append(contentsOf: descendants(of: subview, as: type))
        }
        return found
    }
}
