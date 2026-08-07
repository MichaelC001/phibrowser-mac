// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class DefaultBrowserSectionViewLayoutTests: XCTestCase {
    func testStatusLabelAllowsUnlimitedLines() throws {
        let view = DefaultBrowserSectionView(viewModel: DefaultBrowserViewModel())
        let statusLabel = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)

        XCTAssertEqual(statusLabel.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(statusLabel.maximumNumberOfLines, 0)
        XCTAssertFalse(statusLabel.cell?.usesSingleLineMode ?? true)
        XCTAssertTrue(statusLabel.cell?.wraps ?? false)
    }

    func testStatusLabelCentersSingleAndMultilineContentVertically() throws {
        let view = DefaultBrowserSectionView(viewModel: DefaultBrowserViewModel())
        let statusLabel = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)

        statusLabel.stringValue = "Phi is not your default browser"
        let singleLineBounds = NSRect(x: 0, y: 0, width: 250, height: 56)
        let singleLineRect = try XCTUnwrap(
            statusLabel.cell?.drawingRect(forBounds: singleLineBounds)
        )

        statusLabel.stringValue = "Phi is not your default browser Phi is not your default browser"
        let multilineRect = try XCTUnwrap(
            statusLabel.cell?.drawingRect(forBounds: singleLineBounds)
        )

        XCTAssertEqual(singleLineRect.midY, singleLineBounds.midY, accuracy: 0.5)
        XCTAssertEqual(multilineRect.midY, singleLineBounds.midY, accuracy: 0.5)
        XCTAssertLessThan(singleLineRect.height, multilineRect.height)
    }

    func testSectionIntrinsicHeightGrowsWithWrappedStatus() throws {
        let view = DefaultBrowserSectionView(viewModel: DefaultBrowserViewModel())
        view.frame.size.width = 352
        let statusLabel = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
        statusLabel.stringValue = "Short status"
        let shortHeight = view.intrinsicContentSize.height

        statusLabel.stringValue = String(
            repeating: "A much longer localized default browser status ",
            count: 4
        )
        let wrappedHeight = view.intrinsicContentSize.height

        XCTAssertGreaterThan(wrappedHeight, shortHeight)
    }

    func testButtonRendersDoubledTitleAcrossMultipleLines() throws {
        let view = DefaultBrowserSectionView(viewModel: DefaultBrowserViewModel())
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)
        button.appearance = NSAppearance(named: .aqua)
        button.title = "Set as default Set as default"
        button.frame = NSRect(x: 0, y: 0, width: 145, height: 40)

        let titleRect = try XCTUnwrap(button.cell?.titleRect(forBounds: button.bounds))
        let representation = try renderButton(button)

        let lowerBand = NSRect(
            x: titleRect.minX,
            y: titleRect.minY,
            width: titleRect.width,
            height: titleRect.height / 3
        )
        let upperBand = NSRect(
            x: titleRect.minX,
            y: titleRect.maxY - titleRect.height / 3,
            width: titleRect.width,
            height: titleRect.height / 3
        )

        XCTAssertEqual(button.cell?.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(button.bezelStyle, .regularSquare)
        XCTAssertFalse(button.cell?.usesSingleLineMode ?? true)
        XCTAssertTrue(button.cell?.wraps ?? false)
        XCTAssertGreaterThan(titleRect.height, 20)
        XCTAssertGreaterThan(darkPixelCount(in: lowerBand, of: representation), 5)
        XCTAssertGreaterThan(darkPixelCount(in: upperBand, of: representation), 5)
        XCTAssertLessThan(
            brightness(at: NSPoint(x: button.bounds.midX, y: 2), in: representation),
            0.98
        )
        XCTAssertLessThan(
            brightness(
                at: NSPoint(x: button.bounds.midX, y: button.bounds.maxY - 2),
                in: representation
            ),
            0.98
        )
    }

    private func renderButton(_ button: NSButton) throws -> NSBitmapImageRep {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(button.bounds.width),
            pixelsHigh: Int(button.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        representation.size = button.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: representation))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        button.bounds.fill()
        let cell = try XCTUnwrap(button.cell as? NSButtonCell)
        cell.draw(withFrame: button.bounds, in: button)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return representation
    }

    private func darkPixelCount(
        in rect: NSRect,
        of representation: NSBitmapImageRep
    ) -> Int {
        let scaleX = CGFloat(representation.pixelsWide) / representation.size.width
        let scaleY = CGFloat(representation.pixelsHigh) / representation.size.height
        let minX = max(0, Int(floor(rect.minX * scaleX)))
        let maxX = min(representation.pixelsWide, Int(ceil(rect.maxX * scaleX)))
        let minY = max(0, Int(floor(rect.minY * scaleY)))
        let maxY = min(representation.pixelsHigh, Int(ceil(rect.maxY * scaleY)))

        var count = 0
        for x in minX..<maxX {
            for y in minY..<maxY {
                guard let color = representation.colorAt(x: x, y: y),
                      let rgbColor = color.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = (rgbColor.redComponent
                    + rgbColor.greenComponent
                    + rgbColor.blueComponent) / 3
                if rgbColor.alphaComponent > 0.5, brightness < 0.4 {
                    count += 1
                }
            }
        }
        return count
    }

    private func brightness(
        at point: NSPoint,
        in representation: NSBitmapImageRep
    ) -> CGFloat {
        let scaleX = CGFloat(representation.pixelsWide) / representation.size.width
        let scaleY = CGFloat(representation.pixelsHigh) / representation.size.height
        guard let color = representation.colorAt(
            x: Int(point.x * scaleX),
            y: Int(point.y * scaleY)
        ), let rgbColor = color.usingColorSpace(.deviceRGB) else {
            return 1
        }
        return (rgbColor.redComponent
            + rgbColor.greenComponent
            + rgbColor.blueComponent) / 3
    }
}
