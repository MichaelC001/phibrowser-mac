// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ObjectiveC
import SwiftUI

private enum FullTitleDisplayMetrics {
    static let minimumScaleFactor: CGFloat = 0.01
    static let measurementTolerance: CGFloat = 0.25
    static let searchIterationCount = 14
}

extension View {
    /// Keeps single-line title content visible by shrinking it when space is constrained.
    func requiresFullTitleDisplay(_ required: Bool = true) -> some View {
        lineLimit(required ? 1 : nil)
            .minimumScaleFactor(required ? FullTitleDisplayMetrics.minimumScaleFactor : 1)
            .allowsTightening(required)
    }
}

enum FullTitleDisplayFitter {
    static func fittingScale(
        for values: [NSAttributedString],
        availableSize: NSSize,
        fallbackFont: NSFont
    ) -> CGFloat {
        let values = values.filter { $0.length > 0 }
        guard !values.isEmpty,
              availableSize.width > 0,
              availableSize.height > 0 else {
            return 1
        }

        func fits(_ scale: CGFloat) -> Bool {
            values.allSatisfy { value in
                let size = scaled(value, by: scale, fallbackFont: fallbackFont).size()
                return size.width <= availableSize.width + FullTitleDisplayMetrics.measurementTolerance
                    && size.height <= availableSize.height + FullTitleDisplayMetrics.measurementTolerance
            }
        }

        guard !fits(1) else { return 1 }

        var lowerBound = FullTitleDisplayMetrics.minimumScaleFactor
        var upperBound: CGFloat = 1

        guard fits(lowerBound) else { return lowerBound }

        for _ in 0..<FullTitleDisplayMetrics.searchIterationCount {
            let candidate = (lowerBound + upperBound) / 2
            if fits(candidate) {
                lowerBound = candidate
            } else {
                upperBound = candidate
            }
        }

        return lowerBound
    }

    static func scaled(
        _ value: NSAttributedString,
        by scale: CGFloat,
        fallbackFont: NSFont
    ) -> NSAttributedString {
        guard value.length > 0, scale < 1 else { return value }

        let result = NSMutableAttributedString(attributedString: value)
        let fullRange = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(.font, in: fullRange) { fontValue, range, _ in
            let font = fontValue as? NSFont ?? fallbackFont
            let pointSize = max(0.1, font.pointSize * scale)
            let scaledFont = NSFont(descriptor: font.fontDescriptor, size: pointSize) ?? font
            result.addAttribute(.font, value: scaledFont, range: range)
        }
        return result
    }
}

private var buttonFullTitleDisplayControllerKey: UInt8 = 0
private var textFieldFullTitleDisplayControllerKey: UInt8 = 0

extension NSButton {
    /// When enabled, scales the button title to keep it fully visible on one line.
    var requiresFullTitleDisplay: Bool {
        get { fullTitleDisplayController != nil }
        set {
            if newValue {
                guard fullTitleDisplayController == nil else {
                    fullTitleDisplayController?.update()
                    return
                }
                fullTitleDisplayController = ButtonFullTitleDisplayController(button: self)
            } else {
                fullTitleDisplayController?.restore()
                fullTitleDisplayController = nil
            }
        }
    }

    private var fullTitleDisplayController: ButtonFullTitleDisplayController? {
        get {
            objc_getAssociatedObject(self, &buttonFullTitleDisplayControllerKey)
                as? ButtonFullTitleDisplayController
        }
        set {
            objc_setAssociatedObject(
                self,
                &buttonFullTitleDisplayControllerKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

extension NSTextField {
    /// When enabled, scales the text field value to keep it fully visible on one line.
    var requiresFullTitleDisplay: Bool {
        get { fullTitleDisplayController != nil }
        set {
            if newValue {
                guard fullTitleDisplayController == nil else {
                    fullTitleDisplayController?.update()
                    return
                }
                fullTitleDisplayController = TextFieldFullTitleDisplayController(textField: self)
            } else {
                fullTitleDisplayController?.restore()
                fullTitleDisplayController = nil
            }
        }
    }

    private var fullTitleDisplayController: TextFieldFullTitleDisplayController? {
        get {
            objc_getAssociatedObject(self, &textFieldFullTitleDisplayControllerKey)
                as? TextFieldFullTitleDisplayController
        }
        set {
            objc_setAssociatedObject(
                self,
                &textFieldFullTitleDisplayControllerKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

private final class ButtonFullTitleDisplayController {
    private weak var button: NSButton?
    private var sourceTitle: NSAttributedString
    private var sourceAlternateTitle: NSAttributedString
    private let originalLineBreakMode: NSLineBreakMode?
    private let originalUsesSingleLineMode: Bool?
    private let originalPostsFrameChangedNotifications: Bool
    private let originalPostsBoundsChangedNotifications: Bool
    private var plainTitleObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var alternateTitleObservation: NSKeyValueObservation?
    private var imageObservation: NSKeyValueObservation?
    private var imagePositionObservation: NSKeyValueObservation?
    private var frameObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?
    private var isUpdating = false

    init(button: NSButton) {
        self.button = button
        self.sourceTitle = button.attributedTitle
        self.sourceAlternateTitle = button.attributedAlternateTitle
        self.originalLineBreakMode = button.cell?.lineBreakMode
        self.originalUsesSingleLineMode = button.cell?.usesSingleLineMode
        self.originalPostsFrameChangedNotifications = button.postsFrameChangedNotifications
        self.originalPostsBoundsChangedNotifications = button.postsBoundsChangedNotifications

        button.cell?.usesSingleLineMode = true
        button.cell?.lineBreakMode = .byClipping
        button.postsFrameChangedNotifications = true
        button.postsBoundsChangedNotifications = true

        plainTitleObservation = button.observe(\.title, options: [.new]) { [weak self] button, _ in
            guard let self, !self.isUpdating else { return }
            self.sourceTitle = button.attributedTitle
            self.update()
        }
        titleObservation = button.observe(\.attributedTitle, options: [.new]) { [weak self] button, _ in
            guard let self, !self.isUpdating else { return }
            self.sourceTitle = button.attributedTitle
            self.update()
        }
        alternateTitleObservation = button.observe(\.attributedAlternateTitle, options: [.new]) { [weak self] button, _ in
            guard let self, !self.isUpdating else { return }
            self.sourceAlternateTitle = button.attributedAlternateTitle
            self.update()
        }
        imageObservation = button.observe(\.image, options: [.new]) { [weak self] _, _ in
            self?.update()
        }
        imagePositionObservation = button.observe(\.imagePosition, options: [.new]) { [weak self] _, _ in
            self?.update()
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: button,
            queue: .main
        ) { [weak self] _ in
            self?.update()
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: button,
            queue: .main
        ) { [weak self] _ in
            self?.update()
        }

        update()
    }

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func update() {
        guard let button, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let fallbackFont = button.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let values = [sourceTitle, sourceAlternateTitle]
        guard values.contains(where: { $0.length > 0 }) else { return }

        let probeFont = largestFont(in: values, fallbackFont: fallbackFont)
        let probe = NSAttributedString(
            string: String(repeating: "W", count: 100),
            attributes: [.font: probeFont]
        )
        button.attributedTitle = probe
        button.attributedAlternateTitle = probe

        let availableSize = titleAvailableSize(for: button)
        let scale = FullTitleDisplayFitter.fittingScale(
            for: values,
            availableSize: availableSize,
            fallbackFont: fallbackFont
        )
        button.attributedTitle = FullTitleDisplayFitter.scaled(
            sourceTitle,
            by: scale,
            fallbackFont: fallbackFont
        )
        button.attributedAlternateTitle = FullTitleDisplayFitter.scaled(
            sourceAlternateTitle,
            by: scale,
            fallbackFont: fallbackFont
        )
        button.needsDisplay = true
    }

    func restore() {
        guard let button else { return }
        isUpdating = true
        button.attributedTitle = sourceTitle
        button.attributedAlternateTitle = sourceAlternateTitle
        if let originalLineBreakMode {
            button.cell?.lineBreakMode = originalLineBreakMode
        }
        if let originalUsesSingleLineMode {
            button.cell?.usesSingleLineMode = originalUsesSingleLineMode
        }
        button.postsFrameChangedNotifications = originalPostsFrameChangedNotifications
        button.postsBoundsChangedNotifications = originalPostsBoundsChangedNotifications
        button.needsDisplay = true
        isUpdating = false
    }
}

private final class TextFieldFullTitleDisplayController {
    private weak var textField: NSTextField?
    private var sourceValue: NSAttributedString
    private let originalMaximumNumberOfLines: Int
    private let originalAllowsDefaultTightening: Bool
    private let originalLineBreakMode: NSLineBreakMode?
    private let originalUsesSingleLineMode: Bool?
    private let originalPostsFrameChangedNotifications: Bool
    private let originalPostsBoundsChangedNotifications: Bool
    private var stringValueObservation: NSKeyValueObservation?
    private var valueObservation: NSKeyValueObservation?
    private var frameObserver: NSObjectProtocol?
    private var boundsObserver: NSObjectProtocol?
    private var isUpdating = false

    init(textField: NSTextField) {
        self.textField = textField
        self.sourceValue = textField.attributedStringValue
        self.originalMaximumNumberOfLines = textField.maximumNumberOfLines
        self.originalAllowsDefaultTightening = textField.allowsDefaultTighteningForTruncation
        self.originalLineBreakMode = textField.cell?.lineBreakMode
        self.originalUsesSingleLineMode = textField.cell?.usesSingleLineMode
        self.originalPostsFrameChangedNotifications = textField.postsFrameChangedNotifications
        self.originalPostsBoundsChangedNotifications = textField.postsBoundsChangedNotifications

        textField.maximumNumberOfLines = 1
        textField.allowsDefaultTighteningForTruncation = true
        textField.cell?.usesSingleLineMode = true
        textField.cell?.lineBreakMode = .byClipping
        textField.postsFrameChangedNotifications = true
        textField.postsBoundsChangedNotifications = true

        stringValueObservation = textField.observe(\.stringValue, options: [.new]) { [weak self] textField, _ in
            guard let self, !self.isUpdating else { return }
            self.sourceValue = textField.attributedStringValue
            self.update()
        }
        valueObservation = textField.observe(\.attributedStringValue, options: [.new]) { [weak self] textField, _ in
            guard let self, !self.isUpdating else { return }
            self.sourceValue = textField.attributedStringValue
            self.update()
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textField,
            queue: .main
        ) { [weak self] _ in
            self?.update()
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: textField,
            queue: .main
        ) { [weak self] _ in
            self?.update()
        }

        update()
    }

    deinit {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func update() {
        guard let textField, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let fallbackFont = textField.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let availableSize = titleAvailableSize(for: textField)
        let scale = FullTitleDisplayFitter.fittingScale(
            for: [sourceValue],
            availableSize: availableSize,
            fallbackFont: fallbackFont
        )
        textField.attributedStringValue = FullTitleDisplayFitter.scaled(
            sourceValue,
            by: scale,
            fallbackFont: fallbackFont
        )
        textField.needsDisplay = true
    }

    func restore() {
        guard let textField else { return }
        isUpdating = true
        textField.attributedStringValue = sourceValue
        textField.maximumNumberOfLines = originalMaximumNumberOfLines
        textField.allowsDefaultTighteningForTruncation = originalAllowsDefaultTightening
        if let originalLineBreakMode {
            textField.cell?.lineBreakMode = originalLineBreakMode
        }
        if let originalUsesSingleLineMode {
            textField.cell?.usesSingleLineMode = originalUsesSingleLineMode
        }
        textField.postsFrameChangedNotifications = originalPostsFrameChangedNotifications
        textField.postsBoundsChangedNotifications = originalPostsBoundsChangedNotifications
        textField.needsDisplay = true
        isUpdating = false
    }
}

private func titleAvailableSize(for control: NSControl) -> NSSize {
    guard let cell = control.cell else { return control.bounds.size }
    let titleRect = cell.titleRect(forBounds: control.bounds)
    let drawingRect = cell.drawingRect(forBounds: control.bounds)
    return NSSize(
        width: max(0, min(titleRect.width, drawingRect.width, control.bounds.width)),
        height: max(0, min(titleRect.height, drawingRect.height, control.bounds.height))
    )
}

private func largestFont(
    in values: [NSAttributedString],
    fallbackFont: NSFont
) -> NSFont {
    var result = fallbackFont
    for value in values where value.length > 0 {
        let range = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(.font, in: range) { fontValue, _, _ in
            guard let font = fontValue as? NSFont, font.pointSize > result.pointSize else { return }
            result = font
        }
    }
    return result
}
