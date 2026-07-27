// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
final class ArcDataParserTool {
    private static func log(_ message: String) {
        AppLogDebug(message)
    }
    /// Parse StorableSidebar.json and return Space-rooted Bookmark trees
    static func parse(data: Data) throws -> [ArcSpace] {
        let arc = try JSONDecoder().decode(ArcRoot.self, from: data)

        let containerEntries = extractSidebarItemEntries(from: arc.sidebar.containers)
        log("sidebarSyncState.items=\(arc.sidebarSyncState.items.count) sidebar.containers.items=\(containerEntries.count)")

        let sidebarItems = buildSidebarItemMap(
            syncEntries: arc.sidebarSyncState.items,
            overrideEntries: containerEntries
        )
        let bookmarkMap = createBookmarks(from: sidebarItems)
        linkTree(byChildrenOrder: sidebarItems, bookmarks: bookmarkMap)

        let containerSpaceModels = extractSpaceModels(from: arc.sidebar.containers)
        let syncSpaceModels = arc.sidebarSyncState.spaceModels
            .map { extractSpaceModels(from: $0) }
            ?? [:]
        let spaceModels = !containerSpaceModels.isEmpty
            ? containerSpaceModels
            : syncSpaceModels

        let spaces = buildSpaceRoots(
            spaceModels: spaceModels,
            sidebarItems: sidebarItems,
            bookmarkMap: bookmarkMap
        )

        return spaces.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: - Step 1: Build the sidebar item map

    private static func buildSidebarItemMap(
        _ entries: [SidebarItemEntry]
    ) -> [String: SidebarItem] {

        var map: [String: SidebarItem] = [:]
        var currentID: String?

        for entry in entries {
            switch entry {
            case .id(let id):
                currentID = id
            case .object(let wrapper):
                let id = currentID ?? wrapper.value.id
                map[id] = wrapper.value
                currentID = nil
            case .raw(let item):
                let id = currentID ?? item.id
                map[id] = item
                currentID = nil
            }
        }

        return map
    }

    private static func buildSidebarItemMap(
        syncEntries: [SidebarItemEntry],
        overrideEntries: [SidebarItemEntry]
    ) -> [String: SidebarItem] {
        var map = buildSidebarItemMap(syncEntries)
        if !overrideEntries.isEmpty {
            let overrideMap = buildSidebarItemMap(overrideEntries)
            for (id, item) in overrideMap {
                map[id] = item
            }
        }
        return map
    }

    // MARK: - Step 2: Create flat bookmarks

    private static func createBookmarks(
        from items: [String: SidebarItem]
    ) -> [String: Bookmark] {

        var map: [String: Bookmark] = [:]

        for item in items.values {
            let isFolder: Bool
            let title: String
            let url: String?

            switch item.data {
            case .tab(let tab):
                isFolder = false
                title = tab.savedTitle ?? item.title ?? ""
                url = tab.savedURL

            case .list:
                isFolder = true
                title = item.title ?? "Untitled"
                url = nil

            case .container:
                isFolder = true
                title = item.title ?? "Untitled"
                url = nil
            }

            map[item.id] = Bookmark(
                guid: item.id,
                title: title,
                url: url,
                isFolder: isFolder
            )
        }

        return map
    }

    // MARK: - Step 3: Link parent and child relationships

    private static func linkTree(
        byChildrenOrder items: [String: SidebarItem],
        bookmarks: [String: Bookmark]
    ) {
        for b in bookmarks.values {
            b.children.removeAll()
            b.parent = nil
        }

        for parentItem in items.values {
            guard let parentBookmark = bookmarks[parentItem.id] else { continue }

            for childID in parentItem.childrenIds {
                guard let child = bookmarks[childID] else { continue }
                child.parent = parentBookmark
                parentBookmark.children.append(child)
            }
        }
    }

    // MARK: - Step 4: Build Arc space roots

    private static func buildSpaceRoots(
        spaceModels: [String: SpaceWrapper],
        sidebarItems: [String: SidebarItem],
        bookmarkMap: [String: Bookmark]
    ) -> [ArcSpace] {
        var results: [ArcSpace] = []

        for space in spaceModels.values {
            let trimmed = space.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (trimmed?.isEmpty == false ? trimmed : nil)
                ?? NSLocalizedString("oobe.importBrowserData.arc.untitledSpaceName", value: "Untitled Space",
                                     comment: "Arc import - fallback name for an Arc Space with no title")

            let spaceRoot = Bookmark(guid: space.id, title: title, url: nil, isFolder: true)

            let containerIDs = resolveSpaceContainerIDs(space: space, sidebarItems: sidebarItems)
            for cid in containerIDs {
                guard let containerBookmark = bookmarkMap[cid] else { continue }
                for child in containerBookmark.children {
                    if shouldSkipEmptyPlaceholderFolder(child) { continue }
                    if spaceRoot.children.contains(where: { $0.guid == child.guid }) { continue }
                    child.parent = spaceRoot
                    spaceRoot.children.append(child)
                }
            }

            results.append(ArcSpace(id: space.id, title: title, profile: space.profile, root: spaceRoot))
        }

        return results
    }

    // MARK: - Helpers

    private static func extractSpaceModels(
        from containers: [SidebarContainer]
    ) -> [String: SpaceWrapper] {

        var models: [String: SpaceWrapper] = [:]

        for container in containers {
            guard let entries = container.spacesEntries else { continue }

            var currentID: String?
            for entry in entries {
                switch entry {
                case .id(let id):
                    currentID = id
                case .object(let wrapper):
                    let key = wrapper.id.isEmpty
                        ? (currentID ?? UUID().uuidString)
                        : wrapper.id
                    models[key] = wrapper
                    currentID = nil
                }
            }
        }

        return models
    }

    private static func extractSidebarItemEntries(
        from containers: [SidebarContainer]
    ) -> [SidebarItemEntry] {
        var results: [SidebarItemEntry] = []
        for container in containers {
            if let entries = container.itemEntries {
                results.append(contentsOf: entries)
            }
        }
        return results
    }

    private static func extractSpaceModels(
        from entries: [SpaceEntry]
    ) -> [String: SpaceWrapper] {

        var models: [String: SpaceWrapper] = [:]
        var currentID: String?

        for entry in entries {
            switch entry {
            case .id(let id):
                currentID = id
            case .object(let wrapper):
                let key = wrapper.id.isEmpty
                    ? (currentID ?? UUID().uuidString)
                    : wrapper.id
                models[key] = wrapper
                currentID = nil
            }
        }

        return models
    }

    private static func resolveSpaceContainerIDs(
        space: SpaceWrapper,
        sidebarItems: [String: SidebarItem]
    ) -> [String] {
        let idsFromModel = extractPinnedContainerIDs(
            from: space.containerIDs ?? [],
            spaceID: space.id,
            sidebarItems: sidebarItems
        )
        if !idsFromModel.isEmpty {
            return idsFromModel
        }

        return sidebarItems.values.compactMap { item -> String? in
            guard case .container(let refID) = item.data else { return nil }
            guard refID == space.id else { return nil }
            if item.id.lowercased().contains("unpinned") {
                return nil
            }
            return item.id
        }
    }

    private enum SpaceContainerSection {
        case pinned
        case unpinned
        case unspecified
    }

    private static func extractPinnedContainerIDs(
        from containerIDs: [String],
        spaceID: String,
        sidebarItems: [String: SidebarItem]
    ) -> [String] {
        guard !containerIDs.isEmpty else { return [] }

        var results: [String] = []
        var section: SpaceContainerSection = .unspecified

        for id in containerIDs {
            switch id {
            case "pinned":
                section = .pinned
                log("Space \(spaceID) section=pinned")
                continue
            case "unpinned":
                section = .unpinned
                log("Space \(spaceID) section=unpinned")
                continue
            default:
                break
            }

            if section == .unpinned {
                log("Skip unpinned container \(id) for space \(spaceID)")
                continue
            }

            guard let item = sidebarItems[id] else { continue }
            guard case .container(let refID) = item.data, refID == spaceID else { continue }
            results.append(id)
        }

        return results
    }

    private static func shouldSkipEmptyPlaceholderFolder(_ bookmark: Bookmark) -> Bool {
        guard bookmark.isFolder, bookmark.children.isEmpty else { return false }
        let title = (bookmark.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == "Folder"
    }
}

/// A parsed Arc Space with its profile binding and bookmark tree root.
struct ArcSpace {
    let id: String
    let title: String
    let profile: ArcSourceProfile
    let root: ArcDataParserTool.Bookmark
}

/// Which Chromium profile (under Arc/User Data) an Arc Space uses.
/// `.unknown` = the `profile` field was present but in an unrecognized shape;
/// its `directoryName` is nil so the importer must NOT fall back to Default's data.
enum ArcSourceProfile: Decodable, Equatable {
    case `default`
    case custom(directoryBasename: String)
    case unknown

    var directoryName: String? {
        switch self {
        case .default: return "Default"   // client-side literal; never present in the JSON
        case .custom(let basename): return basename
        case .unknown: return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case `default`, custom }
    private struct Custom: Decodable {
        let _0: Inner
        struct Inner: Decodable { let directoryBasename: String }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try? c.decodeIfPresent(Bool.self, forKey: .default)) == true {
            self = .default
        } else if let custom = try? c.decode(Custom.self, forKey: .custom) {
            let basename = custom._0.directoryBasename
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A profile dir must be a single, non-empty path component. Empty,
            // whitespace, path separators, or traversal must NOT reach the bridge:
            // Chromium maps an empty profile to Default (wrong-profile data import)
            // and appends the basename to the Arc User Data path without sanitizing
            // (path escape). Map any invalid value to .unknown → directoryName nil →
            // bookmarks-only, never Default.
            if basename.isEmpty
                || basename.contains("/")
                || basename.contains("\\")
                || basename == "."
                || basename == ".." {
                self = .unknown
            } else {
                self = .custom(directoryBasename: basename)
            }
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized Arc profile shape"))
        }
    }
}

extension ArcDataParserTool {
    struct ArcRoot: Decodable {
        let sidebarSyncState: SidebarSyncState
        let sidebar: SidebarSection
    }
    
    struct SidebarSyncState: Decodable {
        let items: [SidebarItemEntry]
        let spaceModels: [SpaceEntry]?
    }

    enum SidebarItemEntry: Decodable {
        case id(String)
        case object(SidebarItemWrapper)
        case raw(SidebarItem)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .id(s)
            } else if let wrapper = try? c.decode(SidebarItemWrapper.self) {
                self = .object(wrapper)
            } else {
                self = .raw(try c.decode(SidebarItem.self))
            }
        }
    }

    struct SidebarItemWrapper: Decodable {
        let value: SidebarItem
    }
    
    struct SidebarItem: Decodable {
        let id: String
        let parentID: String?
        let childrenIds: [String]
        let title: String?
        let data: SidebarItemData
    }
    
    enum SidebarItemData: Decodable {
        case tab(TabData)
        case list
        case container(spaceRefID: String?)

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            if let tab = try? c.decode(TabData.self, forKey: .tab) {
                self = .tab(tab)
                return
            }

            if c.contains(.list) {
                self = .list
                return
            }

            if let container = try? c.decode(ItemContainer.self, forKey: .itemContainer) {
                self = .container(spaceRefID: container.containerType.spaceItems?._0)
                return
            }

            self = .container(spaceRefID: nil)
        }

        enum CodingKeys: String, CodingKey {
            case tab
            case list
            case itemContainer
        }
    }
    
    struct TabData: Decodable {
        let savedURL: String
        let savedTitle: String?
    }
    
    struct ItemContainer: Decodable {
        let containerType: ContainerType
    }

    struct ContainerType: Decodable {
        let spaceItems: SpaceItemsRef?
    }

    struct SpaceItemsRef: Decodable {
        let _0: String
    }
    
    struct SidebarSection: Decodable {
        let containers: [SidebarContainer]
    }

    enum SidebarContainer: Decodable {
        case global
        case spaces([SpaceEntry])
        case items([SidebarItemEntry])
        case payload(spaces: [SpaceEntry], items: [SidebarItemEntry])

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.spaces) {
                let spaces = try c.decode([SpaceEntry].self, forKey: .spaces)
                if c.contains(.items) {
                    let items = try c.decode([SidebarItemEntry].self, forKey: .items)
                    self = .payload(spaces: spaces, items: items)
                } else {
                    self = .spaces(spaces)
                }
            } else if c.contains(.items) {
                self = .items(try c.decode([SidebarItemEntry].self, forKey: .items))
            } else {
                self = .global
            }
        }

        enum CodingKeys: String, CodingKey {
            case global
            case spaces
            case items
        }

        var spacesEntries: [SpaceEntry]? {
            switch self {
            case .spaces(let entries):
                return entries
            case .payload(let spaces, _):
                return spaces
            default:
                return nil
            }
        }

        var itemEntries: [SidebarItemEntry]? {
            switch self {
            case .items(let entries):
                return entries
            case .payload(_, let items):
                return items
            default:
                return nil
            }
        }
    }
    
    enum SpaceEntry: Decodable {
        case id(String)
        case object(SpaceWrapper)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                self = .id(s)
            } else if let wrapper = try? c.decode(SpaceModelWrapper.self) {
                self = .object(wrapper.value)
            } else {
                self = .object(try c.decode(SpaceWrapper.self))
            }
        }
    }

    struct SpaceModelWrapper: Decodable {
        let value: SpaceWrapper
    }

    struct SpaceWrapper: Decodable {
        let id: String
        let title: String?
        let containerIDs: [String]?
        let profile: ArcSourceProfile

        private enum CodingKeys: String, CodingKey { case id, title, containerIDs, profile }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            containerIDs = (try? c.decode([String].self, forKey: .containerIDs)) ?? []
            if c.contains(.profile) {
                profile = (try? c.decode(ArcSourceProfile.self, forKey: .profile)) ?? .unknown
            } else {
                profile = .default
            }
        }
    }
    
    class Bookmark {
        var title: String?
        var guid: String
        var children: [Bookmark]
        var url: String?
        var isFolder: Bool
        var parent: Bookmark? = nil
        init(guid: String, title: String, children: [Bookmark] = [], url: String?, isFolder: Bool) {
            self.title = title
            self.guid = guid
            self.children = children
            self.url = url
            self.isFolder = isFolder
        }
    }
}
