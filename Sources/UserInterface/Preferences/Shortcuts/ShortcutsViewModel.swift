// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
class ShortcutsViewModel: ObservableObject {
    @Published var sections: [(category: String, items: [ShortcutItem])] = []
    @Published var editingCommand: CommandWrapper?
    @Published var hiddenGroups: Set<Shortcuts.Group> = [.help, .bookmarks]
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        SpaceManager.shared.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)
        rebuildSections()
    }
    
    func rebuildSections() {
        var newSections: [(category: String, items: [ShortcutItem])] = []
        
        Shortcuts.Group.allCases
            .filter { !hiddenGroups.contains($0) }
            .forEach { group in
                let items = group.commands.compactMap { command -> ShortcutItem? in
                    guard shouldShow(command) else { return nil }
                    let key = Shortcuts.key(for: command)
                    let conflictingCommands = findConflictingCommands(for: command, currentKey: key)
                    
                    return ShortcutItem(
                        id: command,
                        command: command,
                        name: displayName(for: command),
                        shortcutKey: key,
                        shortcutDisplay: key?.displayString ?? NSLocalizedString("Add New", comment: "Shortcuts settings - Placeholder text when no shortcut is assigned"),
                        isOverridden: Shortcuts.isOverridden(command),
                        conflictingCommandNames: conflictingCommands.map { displayName(for: $0) },
                        searchKeywords: searchKeywords(for: command)
                    )
                }
                
                if !items.isEmpty {
                    newSections.append((category: group.title, items: items))
                }
            }
        
        sections = newSections
    }
    
    private func findConflictingCommands(for command: CommandWrapper, currentKey: ShortcutsKey?) -> [CommandWrapper] {
        guard let currentKey = currentKey else { return [] }
        
        var conflicts: [CommandWrapper] = []
        
        Shortcuts.DefaultShortcuts.keys.forEach { otherCommand in
            guard otherCommand != command else { return }
            guard shouldShow(otherCommand) else { return }
            if let otherKey = Shortcuts.key(for: otherCommand),
               otherKey == currentKey {
                conflicts.append(otherCommand)
            }
        }
        return conflicts
    }

    private func shouldShow(_ command: CommandWrapper) -> Bool {
        guard let index = command.spaceSelectionIndex else {
            return true
        }
        return index < SpaceManager.shared.spaces.count
    }

    private func displayName(for command: CommandWrapper) -> String {
        if let index = command.spaceSelectionIndex {
            let spaces = SpaceManager.shared.spaces
            if spaces.indices.contains(index) {
                return String(
                    format: NSLocalizedString("Go to Space \"%@\"", comment: "Shortcuts settings - Command title to activate the Space at this position"),
                    spaces[index].name
                )
            }
        }
        return command.displayName
    }

    private func searchKeywords(for command: CommandWrapper) -> [String] {
        var keywords = command.searchKeywords
        if let index = command.spaceSelectionIndex {
            let spaces = SpaceManager.shared.spaces
            if spaces.indices.contains(index) {
                keywords.append(spaces[index].name)
                keywords.append("space \(index + 1)")
            }
        }
        return Array(Set(keywords.map { $0.lowercased() }))
    }
    
    func setCustomShortcut(for command: CommandWrapper, keyChord: KeyChord) {
        let key = ShortcutsKey(characters: keyChord.characters, modifiers: keyChord.modifiers)
        
        Shortcuts.override(key, for: command)
        rebuildSections()
    }
    
    /// Disables the shortcut by storing an explicit empty override.
    func disableShortcut(for command: CommandWrapper) {
        Shortcuts.override(nil, for: command, remove: false)
        rebuildSections()
    }
    
    /// Restores the default shortcut for the command.
    func restoreDefaultShortcut(for command: CommandWrapper) {
        Shortcuts.override(nil, for: command, remove: true)
        rebuildSections()
    }
    
    func restoreAllShortcuts() {
        Shortcuts.restoreOverrides()
        rebuildSections()
    }
    
    private func normalizeCharacters(_ characters: String) -> String {
        if characters == String(format: "%c", NSDeleteCharacter) {
            return String(format: "%c", NSBackspaceCharacter)
        }
        if characters.count > 1 {
            return String(characters.prefix(1))
        }
        return characters.lowercased()
    }
}

struct ShortcutItem: Identifiable {
    let id: CommandWrapper
    let command: CommandWrapper
    let name: String
    let shortcutKey: ShortcutsKey?
    let shortcutDisplay: String
    let isOverridden: Bool
    let conflictingCommandNames: [String]
    let searchKeywords: [String]
    
    var hasConflict: Bool {
        !conflictingCommandNames.isEmpty
    }
}

struct KeyChord {
    let characters: String
    let modifiers: NSEvent.ModifierFlags
    
    init?(fromEvent event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
            return nil
        }
        
        let relevantModifierFlags: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let modifiers = event.modifierFlags.intersection(relevantModifierFlags)
        if modifiers.isEmpty {
            return nil
        }
        
        // Shift-Tab may arrive as NSBackTabCharacter. Store every physical Tab
        // key as "\t" so recording matches CommandDispatcher's event lookup.
        var normalizedChars = chars
        if event.keyCode == 48 {
            normalizedChars = "\t"
        } else if chars == String(format: "%c", NSDeleteCharacter) {
            normalizedChars = String(format: "%c", NSBackspaceCharacter)
        } else if chars.count > 1 {
            normalizedChars = String(chars.prefix(1))
        }
        normalizedChars = normalizedChars.lowercased()
        
        self.characters = normalizedChars
        self.modifiers = modifiers
    }
}
