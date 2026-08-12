// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// A native two-column bookmark row used by the bookmark manager outline.
final class BookmarkManagerCellView: NSTableCellView, NSTextFieldDelegate {
    enum Column {
        case website
        case address
    }

    private(set) var representedBookmarkGuid: String?

    private let primaryIconView = BookmarkManagerCellView.makeIconView()
    private let secondaryIconView = BookmarkManagerCellView.makeIconView()
    private let iconStack = NSStackView()
    private let valueField = NSTextField()

    private var valueLeadingToIconsConstraint: NSLayoutConstraint?
    private var valueLeadingToCellConstraint: NSLayoutConstraint?
    private var primaryFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var secondaryFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var representedScope: BookmarkManagementScope?
    private var configuredColumn: Column = .website
    private var configuredEditableValue: String?
    private var originalEditingValue = ""
    private var commitHandler: ((String) -> Bool)?
    private var isEditingValue = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildLayout()
    }

    deinit {
        primaryFaviconHandle?.cancel()
        secondaryFaviconHandle?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopEditingWithoutCommit()
        cancelFaviconLoads()
        representedBookmarkGuid = nil
        representedScope = nil
        configuredEditableValue = nil
        commitHandler = nil
        primaryIconView.image = nil
        secondaryIconView.image = nil
        secondaryIconView.isHidden = true
        valueField.stringValue = ""
        valueField.toolTip = nil
    }

    func configure(
        bookmark: Bookmark,
        scope: BookmarkManagementScope,
        column: Column,
        onCommit: ((String) -> Bool)?
    ) {
        stopEditingWithoutCommit()
        cancelFaviconLoads()

        representedBookmarkGuid = bookmark.guid
        representedScope = scope
        configuredColumn = column
        commitHandler = onCommit

        let isSplit = bookmark.secondaryUrl?.isEmpty == false
        switch column {
        case .website:
            configureWebsite(bookmark: bookmark, scope: scope, isSplit: isSplit)
            configuredEditableValue = (isSplit || onCommit == nil) ? nil : bookmark.title
        case .address:
            configureAddress(bookmark: bookmark, isSplit: isSplit)
            configuredEditableValue = (onCommit != nil && !bookmark.isFolder && !isSplit) ? bookmark.url : nil
        }

        valueField.toolTip = valueField.stringValue
        updateEditingAppearance(isEditing: false)
    }

    func beginEditing() {
        guard !isEditingValue,
              let editableValue = configuredEditableValue,
              let window else {
            return
        }

        isEditingValue = true
        originalEditingValue = editableValue
        valueField.stringValue = editableValue
        updateEditingAppearance(isEditing: true)

        window.makeFirstResponder(valueField)
        valueField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditingValue, notification.object as? NSTextField === valueField else {
            return
        }
        if let movement = notification.userInfo?["NSTextMovement"] as? Int,
           movement == NSTextMovement.cancel.rawValue {
            cancelEditing()
            return
        }
        commitEditing(valueField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === valueField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitEditing(textView.string)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        return false
    }

    private func buildLayout() {
        iconStack.orientation = .horizontal
        iconStack.alignment = .centerY
        iconStack.spacing = 4
        iconStack.translatesAutoresizingMaskIntoConstraints = false
        iconStack.addArrangedSubview(primaryIconView)
        iconStack.addArrangedSubview(secondaryIconView)

        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.delegate = self
        valueField.font = .systemFont(ofSize: 13)
        valueField.isEditable = false
        valueField.isSelectable = false
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.focusRingType = .none
        valueField.usesSingleLineMode = true
        valueField.lineBreakMode = .byTruncatingTail
        valueField.cell?.isScrollable = true
        valueField.cell?.wraps = false
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconStack)
        addSubview(valueField)
        textField = valueField
        imageView = primaryIconView

        let leadingToIcons = valueField.leadingAnchor.constraint(equalTo: iconStack.trailingAnchor, constant: 8)
        let leadingToCell = valueField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        valueLeadingToIconsConstraint = leadingToIcons
        valueLeadingToCellConstraint = leadingToCell

        NSLayoutConstraint.activate([
            iconStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            primaryIconView.widthAnchor.constraint(equalToConstant: 16),
            primaryIconView.heightAnchor.constraint(equalToConstant: 16),
            secondaryIconView.widthAnchor.constraint(equalToConstant: 16),
            secondaryIconView.heightAnchor.constraint(equalToConstant: 16),
            valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            leadingToIcons,
        ])
    }

    private func configureWebsite(
        bookmark: Bookmark,
        scope: BookmarkManagementScope,
        isSplit: Bool
    ) {
        setShowsIcons(true)
        valueField.stringValue = bookmark.title
        valueField.textColor = .labelColor

        if bookmark.isFolder {
            primaryIconView.image = NSImage(resource: .folderClose)
            primaryIconView.contentTintColor = .secondaryLabelColor
            secondaryIconView.image = nil
            secondaryIconView.isHidden = true
            return
        }

        primaryIconView.contentTintColor = nil
        secondaryIconView.contentTintColor = nil
        secondaryIconView.isHidden = !isSplit
        loadFavicon(
            into: primaryIconView,
            pageURLString: bookmark.url,
            snapshotData: bookmark.liveFaviconData ?? bookmark.cachedFaviconData,
            scope: scope,
            expectedGuid: bookmark.guid,
            isPrimary: true
        )
        if isSplit {
            loadFavicon(
                into: secondaryIconView,
                pageURLString: bookmark.secondaryUrl,
                snapshotData: nil,
                scope: scope,
                expectedGuid: bookmark.guid,
                isPrimary: false
            )
        } else {
            secondaryIconView.image = nil
        }
    }

    private func configureAddress(bookmark: Bookmark, isSplit: Bool) {
        setShowsIcons(false)
        valueField.textColor = .secondaryLabelColor
        primaryIconView.image = nil
        secondaryIconView.image = nil
        secondaryIconView.isHidden = true

        if bookmark.isFolder {
            valueField.stringValue = Self.localizedChildCount(bookmark.children.count)
        } else if isSplit {
            valueField.stringValue = "\(bookmark.url ?? "") | \(bookmark.secondaryUrl ?? "")"
        } else {
            valueField.stringValue = bookmark.url ?? ""
        }
    }

    private func setShowsIcons(_ showsIcons: Bool) {
        iconStack.isHidden = !showsIcons
        valueLeadingToIconsConstraint?.isActive = showsIcons
        valueLeadingToCellConstraint?.isActive = !showsIcons
    }

    private func loadFavicon(
        into imageView: NSImageView,
        pageURLString: String?,
        snapshotData: Data?,
        scope: BookmarkManagementScope,
        expectedGuid: String,
        isPrimary: Bool
    ) {
        imageView.image = Self.faviconPlaceholder
        let request = ProfileScopedFaviconRequest(
            profileId: scope.profileId,
            pageURLString: pageURLString,
            snapshotData: snapshotData
        )
        let handle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self, weak imageView] result in
            guard let self,
                  self.representedBookmarkGuid == expectedGuid,
                  self.representedScope == scope,
                  self.configuredColumn == .website else {
                return
            }
            imageView?.image = result.image
        }
        if isPrimary {
            primaryFaviconHandle = handle
        } else {
            secondaryFaviconHandle = handle
        }
    }

    private func cancelFaviconLoads() {
        primaryFaviconHandle?.cancel()
        primaryFaviconHandle = nil
        secondaryFaviconHandle?.cancel()
        secondaryFaviconHandle = nil
    }

    private func commitEditing(_ value: String) {
        guard isEditingValue else { return }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            NSSound.beep()
            finishEditing(displayedValue: originalEditingValue)
            return
        }

        guard commitHandler?(trimmedValue) == true else {
            NSSound.beep()
            finishEditing(displayedValue: originalEditingValue)
            return
        }

        configuredEditableValue = trimmedValue
        finishEditing(displayedValue: trimmedValue)
    }

    private func cancelEditing() {
        guard isEditingValue else { return }
        finishEditing(displayedValue: originalEditingValue)
    }

    private func finishEditing(displayedValue: String) {
        isEditingValue = false
        valueField.stringValue = displayedValue
        valueField.toolTip = displayedValue
        updateEditingAppearance(isEditing: false)
        if valueField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
    }

    private func stopEditingWithoutCommit() {
        guard isEditingValue else { return }
        isEditingValue = false
        valueField.stringValue = originalEditingValue
        updateEditingAppearance(isEditing: false)
        if valueField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
    }

    private func updateEditingAppearance(isEditing: Bool) {
        valueField.isEditable = isEditing
        valueField.isSelectable = isEditing
        valueField.drawsBackground = isEditing
        valueField.backgroundColor = isEditing ? .textBackgroundColor : .clear
        valueField.focusRingType = isEditing ? .default : .none
    }

    private static func makeIconView() -> NSImageView {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 3
        imageView.layer?.masksToBounds = true
        return imageView
    }

    private static func localizedChildCount(_ count: Int) -> String {
        if count == 1 {
            return NSLocalizedString(
                "bookmarkManager.folder.singleChildCount",
                value: "1 item",
                comment: "Bookmark manager Address column - child count for a folder containing one item"
            )
        }
        let format = NSLocalizedString(
            "bookmarkManager.folder.multipleChildCount",
            value: "%d items",
            comment: "Bookmark manager Address column - child count for a folder containing zero or multiple items"
        )
        return String.localizedStringWithFormat(format, count)
    }

    private static let faviconPlaceholder = NSImage(
        systemSymbolName: "globe",
        accessibilityDescription: NSLocalizedString(
            "bookmarkManager.faviconPlaceholderAccessibilityLabel",
            value: "Website",
            comment: "Bookmark manager - Accessibility description for a placeholder website favicon"
        )
    ) ?? NSImage()
}
