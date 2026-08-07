// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class FullTitleDisplayTests: XCTestCase {
    func testFitterPreservesOriginalSizeWhenTitleFits() {
        let font = NSFont.systemFont(ofSize: 13)
        let title = NSAttributedString(string: "Chat", attributes: [.font: font])

        let scale = FullTitleDisplayFitter.fittingScale(
            for: [title],
            availableSize: NSSize(width: 100, height: 30),
            fallbackFont: font
        )

        XCTAssertEqual(scale, 1)
    }

    func testFitterShrinksTitleAndPreservesAttributes() throws {
        let font = NSFont.boldSystemFont(ofSize: 20)
        let title = NSAttributedString(
            string: "A long localized title",
            attributes: [.font: font, .foregroundColor: NSColor.systemRed]
        )
        let availableSize = NSSize(width: 60, height: 24)

        let scale = FullTitleDisplayFitter.fittingScale(
            for: [title],
            availableSize: availableSize,
            fallbackFont: font
        )
        let fittedTitle = FullTitleDisplayFitter.scaled(
            title,
            by: scale,
            fallbackFont: font
        )
        let fittedFont = try XCTUnwrap(fittedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        XCTAssertLessThan(scale, 1)
        XCTAssertLessThan(fittedFont.pointSize, font.pointSize)
        XCTAssertLessThanOrEqual(fittedTitle.size().width, availableSize.width + 0.25)
        XCTAssertEqual(
            fittedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .systemRed
        )
    }

    func testButtonPropertyRefitsWhenWidthChangesAndRestoresOriginalFont() throws {
        let button = NSButton(title: "A long localized button title", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 80, height: 26)
        let originalFont = try titleFont(in: button.attributedTitle)

        button.requiresFullTitleDisplay = true
        let compactFont = try titleFont(in: button.attributedTitle)

        XCTAssertTrue(button.requiresFullTitleDisplay)
        XCTAssertEqual(button.title, "A long localized button title")
        XCTAssertLessThan(compactFont.pointSize, originalFont.pointSize)

        button.title = "A different localized button title"
        let updatedFont = try titleFont(in: button.attributedTitle)
        XCTAssertEqual(button.title, "A different localized button title")
        XCTAssertLessThan(updatedFont.pointSize, originalFont.pointSize)

        button.frame.size.width = 400
        let expandedFont = try titleFont(in: button.attributedTitle)
        XCTAssertEqual(expandedFont.pointSize, originalFont.pointSize, accuracy: 0.01)

        let attributedFont = NSFont.boldSystemFont(ofSize: 18)
        button.frame.size.width = 80
        button.attributedTitle = NSAttributedString(
            string: "An attributed localized button title",
            attributes: [.font: attributedFont, .foregroundColor: NSColor.systemBlue]
        )
        let compactAttributedFont = try titleFont(in: button.attributedTitle)
        XCTAssertLessThan(compactAttributedFont.pointSize, attributedFont.pointSize)
        XCTAssertEqual(
            button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            .systemBlue
        )

        button.frame.size.width = 400
        let expandedAttributedFont = try titleFont(in: button.attributedTitle)
        XCTAssertEqual(expandedAttributedFont.pointSize, attributedFont.pointSize, accuracy: 0.01)

        button.requiresFullTitleDisplay = false
        let restoredFont = try titleFont(in: button.attributedTitle)
        XCTAssertFalse(button.requiresFullTitleDisplay)
        XCTAssertEqual(restoredFont.pointSize, attributedFont.pointSize, accuracy: 0.01)
    }

    func testTextFieldPropertyShrinksAndRestoresOriginalFont() throws {
        let textField = NSTextField(labelWithString: "A long localized text field title")
        textField.frame = NSRect(x: 0, y: 0, width: 70, height: 20)
        let originalFont = try titleFont(in: textField.attributedStringValue)

        textField.requiresFullTitleDisplay = true
        let compactFont = try titleFont(in: textField.attributedStringValue)

        XCTAssertTrue(textField.requiresFullTitleDisplay)
        XCTAssertEqual(textField.stringValue, "A long localized text field title")
        XCTAssertLessThan(compactFont.pointSize, originalFont.pointSize)

        textField.stringValue = "A different localized text field title"
        let updatedFont = try titleFont(in: textField.attributedStringValue)
        XCTAssertEqual(textField.stringValue, "A different localized text field title")
        XCTAssertLessThan(updatedFont.pointSize, originalFont.pointSize)

        textField.requiresFullTitleDisplay = false
        let restoredFont = try titleFont(in: textField.attributedStringValue)
        XCTAssertFalse(textField.requiresFullTitleDisplay)
        XCTAssertEqual(restoredFont.pointSize, originalFont.pointSize, accuracy: 0.01)
    }

    private func titleFont(in value: NSAttributedString) throws -> NSFont {
        try XCTUnwrap(value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    }
}
