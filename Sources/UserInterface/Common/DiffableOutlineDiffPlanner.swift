// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum DiffableOutlineOperation<ItemID: Hashable>: Equatable {
    case remove(id: ItemID, parentID: ItemID?, index: Int)
    case move(id: ItemID, parentID: ItemID?, from: Int, to: Int)
    case insert(id: ItemID, parentID: ItemID?, index: Int)
    case replace(id: ItemID, parentID: ItemID?, index: Int)
    case reload(id: ItemID)
}

struct DiffableOutlinePlan<ItemID: Hashable> {
    let operations: [DiffableOutlineOperation<ItemID>]
    let isSafe: Bool

    static var unsafe: DiffableOutlinePlan<ItemID> {
        DiffableOutlinePlan(operations: [], isSafe: false)
    }
}

enum DiffableOutlineDiffPlanner {
    static func plan<ItemID: Hashable>(
        from old: DiffableOutlineSnapshot<ItemID>,
        to new: DiffableOutlineSnapshot<ItemID>,
        debugLabel: String? = nil
    ) -> DiffableOutlinePlan<ItemID> {
        let totalStart = performanceTimestamp()
        let oldValidationStart = performanceTimestamp()
        let oldValidationError = old.validationError
        let oldValidationMs = elapsedMilliseconds(since: oldValidationStart)
        guard oldValidationError == nil else {
#if DEBUG
            logPerformance(
                debugLabel,
                "stage=planner mode=invalid-old oldNodes=\(old.nodes.count) newNodes=\(new.nodes.count) " +
                "validationMode=checked " +
                "oldValidationMs=\(formatMilliseconds(oldValidationMs)) " +
                "totalMs=\(formatMilliseconds(elapsedMilliseconds(since: totalStart)))"
            )
#endif
            return .unsafe
        }
        let newValidationStart = performanceTimestamp()
        let newValidationError = new.validationError
        let newValidationMs = elapsedMilliseconds(since: newValidationStart)
        guard newValidationError == nil else {
#if DEBUG
            logPerformance(
                debugLabel,
                "stage=planner mode=invalid-new oldNodes=\(old.nodes.count) newNodes=\(new.nodes.count) " +
                "validationMode=checked " +
                "oldValidationMs=\(formatMilliseconds(oldValidationMs)) " +
                "newValidationMs=\(formatMilliseconds(newValidationMs)) " +
                "totalMs=\(formatMilliseconds(elapsedMilliseconds(since: totalStart)))"
            )
#endif
            return .unsafe
        }

        return makePlan(
            from: old,
            to: new,
            debugLabel: debugLabel,
            validationMode: "checked",
            oldValidationMs: oldValidationMs,
            newValidationMs: newValidationMs,
            totalStart: totalStart
        )
    }

    /// Plans without validating either snapshot. Callers must only use this
    /// after validating `new` in the current transaction and proving `old`
    /// came from a previously accepted, validated transaction.
    static func planValidated<ItemID: Hashable>(
        from old: DiffableOutlineSnapshot<ItemID>,
        to new: DiffableOutlineSnapshot<ItemID>,
        debugLabel: String? = nil
    ) -> DiffableOutlinePlan<ItemID> {
        makePlan(
            from: old,
            to: new,
            debugLabel: debugLabel,
            validationMode: "prevalidated",
            oldValidationMs: 0,
            newValidationMs: 0,
            totalStart: performanceTimestamp()
        )
    }

    private static func makePlan<ItemID: Hashable>(
        from old: DiffableOutlineSnapshot<ItemID>,
        to new: DiffableOutlineSnapshot<ItemID>,
        debugLabel: String?,
        validationMode: String,
        oldValidationMs: Double,
        newValidationMs: Double,
        totalStart: CFAbsoluteTime
    ) -> DiffableOutlinePlan<ItemID> {
        let diffCoreStart = performanceTimestamp()

        let oldIDs = Set(old.nodes.keys)
        let newIDs = Set(new.nodes.keys)
        let removedIDs = oldIDs.subtracting(newIDs)
        let insertedIDs = newIDs.subtracting(oldIDs)
        let commonIDs = oldIDs.intersection(newIDs)
        let crossParentMovedIDs = Set(commonIDs.filter { old.parentID(of: $0) != new.parentID(of: $0) })

        let structuralRemovedIDs = removedIDs.union(crossParentMovedIDs)
        let structuralInsertedIDs = insertedIDs.union(crossParentMovedIDs)
        let initialHighestRemoved = Set(structuralRemovedIDs.filter { !old.hasAncestor(of: $0, in: structuralRemovedIDs) })
        let initialHighestInserted = Set(structuralInsertedIDs.filter { !new.hasAncestor(of: $0, in: structuralInsertedIDs) })
        let initialStructuralCoveredIDs = coveredIDs(initialHighestRemoved, in: old)
            .union(coveredIDs(initialHighestInserted, in: new))
        let highestReplaced = highestReplacementIDs(
            replacementIDs(old: old, new: new, excludedIDs: initialStructuralCoveredIDs),
            in: new
        )
        for id in highestReplaced {
            guard old.parentID(of: id) == new.parentID(of: id),
                  let oldIndex = old.index(of: id),
                  let newIndex = new.index(of: id),
                  oldIndex == newIndex
            else {
                return .unsafe
            }
        }
        let replacementCoveredOldIDs = coveredIDs(highestReplaced, in: old)
        let replacementCoveredNewIDs = coveredIDs(highestReplaced, in: new)
        let highestRemoved = Set(initialHighestRemoved.filter { id in
            crossParentMovedIDs.contains(id) || !replacementCoveredOldIDs.contains(id)
        })
        let highestInserted = Set(initialHighestInserted.filter { id in
            !replacementCoveredNewIDs.contains(id)
        })
        let structuralCoveredIDs = coveredIDs(highestRemoved, in: old)
            .union(coveredIDs(highestInserted, in: new))
        let siblingDiffParentIDs = parentIDsForSiblingDiff(old: old, new: new)
        let structuralChanges = structuralOperations(
            old: old,
            new: new,
            highestRemoved: highestRemoved,
            highestInserted: highestInserted,
            parentIDs: siblingDiffParentIDs
        )
        let moveExcludedIDs = structuralCoveredIDs
            .union(replacementCoveredOldIDs)
            .union(replacementCoveredNewIDs)
        let moves = sameParentMoves(
            old: old,
            new: new,
            excludedIDs: moveExcludedIDs,
            parentIDs: siblingDiffParentIDs
        )
        let replacementSiblingParentIDs = Set(highestReplaced.map { new.parentID(of: $0) })
        let hasReplacementSiblingMove = moves.contains { operation in
            guard case .move(_, let parentID, _, _) = operation else { return false }
            return replacementSiblingParentIDs.contains(parentID)
        }
        let replacementSiblingStructureMatchesNewSnapshot = replacementSiblingStructureIsSafe(
            old: old,
            new: new,
            parentIDs: replacementSiblingParentIDs,
            removes: structuralChanges.removes,
            inserts: structuralChanges.inserts
        )
        if hasReplacementSiblingMove || !replacementSiblingStructureMatchesNewSnapshot {
            return .unsafe
        }
        let replacements = replacementOperations(highestReplaced, in: new)
        let reloads = reloads(in: new)

        let plan = DiffableOutlinePlan(
            operations: structuralChanges.removes + moves + structuralChanges.inserts + replacements + reloads,
            isSafe: true
        )
#if DEBUG
        logPerformance(
            debugLabel,
            "stage=planner mode=complete oldNodes=\(old.nodes.count) newNodes=\(new.nodes.count) " +
            "operations=\(plan.operations.count) oldValidationMs=\(formatMilliseconds(oldValidationMs)) " +
            "newValidationMs=\(formatMilliseconds(newValidationMs)) " +
            "validationMode=\(validationMode) " +
            "diffCoreMs=\(formatMilliseconds(elapsedMilliseconds(since: diffCoreStart))) " +
            "totalMs=\(formatMilliseconds(elapsedMilliseconds(since: totalStart)))"
        )
#endif
        return plan
    }

    private static func performanceTimestamp() -> CFAbsoluteTime {
#if DEBUG
        CFAbsoluteTimeGetCurrent()
#else
        0
#endif
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
#if DEBUG
        (CFAbsoluteTimeGetCurrent() - start) * 1000
#else
        0
#endif
    }

#if DEBUG
    private static func logPerformance(_ debugLabel: String?, _ details: String) {
        guard let debugLabel else { return }
        AppLogDebug("[PHI_DEBUG][PIN_CLICK][BM][SIDEBAR_REFRESH] \(debugLabel) \(details)")
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
#endif

    private static func structuralOperations<ItemID: Hashable>(
        old: DiffableOutlineSnapshot<ItemID>,
        new: DiffableOutlineSnapshot<ItemID>,
        highestRemoved: Set<ItemID>,
        highestInserted: Set<ItemID>,
        parentIDs: [ItemID?]
    ) -> DiffableOutlineStructuralOperations<ItemID> {
        var removes: [DiffableOutlineOperation<ItemID>] = []
        var inserts: [DiffableOutlineOperation<ItemID>] = []

        for parentID in parentIDs {
            let oldChildren = old.childIDs(of: parentID)
            let newChildren = new.childIDs(of: parentID)
            guard oldChildren != newChildren else { continue }

            let difference = newChildren.difference(from: oldChildren)
            for change in difference {
                switch change {
                case .remove(let offset, let id, _):
                    guard highestRemoved.contains(id) else { continue }
                    removes.append(.remove(id: id, parentID: parentID, index: offset))
                case .insert(let offset, let id, _):
                    guard highestInserted.contains(id) else { continue }
                    inserts.append(.insert(id: id, parentID: parentID, index: offset))
                }
            }
        }

        return DiffableOutlineStructuralOperations(
            removes: sortedRemoves(removes, in: old),
            inserts: sortedInserts(inserts, in: new)
        )
    }

    private static func sameParentMoves<ItemID: Hashable>(
        old: DiffableOutlineSnapshot<ItemID>,
        new: DiffableOutlineSnapshot<ItemID>,
        excludedIDs: Set<ItemID>,
        parentIDs: [ItemID?]
    ) -> [DiffableOutlineOperation<ItemID>] {
        var operations: [DiffableOutlineOperation<ItemID>] = []

        for parentID in parentIDs {
            let oldChildren = old.childIDs(of: parentID).filter {
                !excludedIDs.contains($0) && new.parentID(of: $0) == parentID
            }
            let newChildren = new.childIDs(of: parentID).filter {
                !excludedIDs.contains($0) && old.parentID(of: $0) == parentID
            }
            guard oldChildren != newChildren else { continue }

            let difference = newChildren.difference(from: oldChildren).inferringMoves()
            guard difference.containsAssociatedMove else { continue }

            var working = oldChildren
            for targetIndex in newChildren.indices {
                let targetID = newChildren[targetIndex]
                guard working.indices.contains(targetIndex), working[targetIndex] != targetID else {
                    continue
                }
                guard let fromIndex = working.firstIndex(of: targetID) else { continue }

                working.remove(at: fromIndex)
                working.insert(targetID, at: targetIndex)
                operations.append(.move(id: targetID, parentID: parentID, from: fromIndex, to: targetIndex))
            }
        }

        return operations
    }

    /// Replays the structural operations that run before replacements and
    /// verifies that each affected sibling list reaches the new snapshot.
    private static func replacementSiblingStructureIsSafe<ItemID: Hashable>(
        old: DiffableOutlineSnapshot<ItemID>,
        new: DiffableOutlineSnapshot<ItemID>,
        parentIDs: Set<ItemID?>,
        removes: [DiffableOutlineOperation<ItemID>],
        inserts: [DiffableOutlineOperation<ItemID>]
    ) -> Bool {
        for parentID in parentIDs {
            var currentIDs = old.childIDs(of: parentID)

            for operation in removes {
                guard case .remove(let id, let operationParentID, let index) = operation,
                      operationParentID == parentID
                else { continue }
                guard currentIDs.indices.contains(index), currentIDs[index] == id else {
                    return false
                }
                currentIDs.remove(at: index)
            }

            for operation in inserts {
                guard case .insert(let id, let operationParentID, let index) = operation,
                      operationParentID == parentID
                else { continue }
                guard index >= 0, index <= currentIDs.count else { return false }
                currentIDs.insert(id, at: index)
            }

            guard currentIDs == new.childIDs(of: parentID) else { return false }
        }

        return true
    }

    private static func replacementIDs<ItemID: Hashable>(
        old: DiffableOutlineSnapshot<ItemID>,
        new: DiffableOutlineSnapshot<ItemID>,
        excludedIDs: Set<ItemID>
    ) -> Set<ItemID> {
        Set(old.nodes.keys).intersection(new.nodes.keys).filter { id in
            guard !excludedIDs.contains(id) else { return false }
            guard let oldItem = old.item(for: id), let newItem = new.item(for: id) else { return false }
            return oldItem !== newItem
        }
    }

    private static func highestReplacementIDs<ItemID: Hashable>(
        _ replacedIDs: Set<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> Set<ItemID> {
        Set(replacedIDs.filter { !snapshot.hasAncestor(of: $0, in: replacedIDs) })
    }

    private static func replacementOperations<ItemID: Hashable>(
        _ highestReplaced: Set<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> [DiffableOutlineOperation<ItemID>] {
        return highestReplaced
            .compactMap { id -> DiffableOutlineOperation<ItemID>? in
                guard let index = snapshot.index(of: id) else { return nil }
                return .replace(id: id, parentID: snapshot.parentID(of: id), index: index)
            }
            .sorted { lhs, rhs in
                let left = replacementSortKey(lhs, in: snapshot)
                let right = replacementSortKey(rhs, in: snapshot)
                if left.depth != right.depth { return left.depth < right.depth }
                if left.parent != right.parent { return left.parent < right.parent }
                return left.index < right.index
            }
    }

    private static func reloads<ItemID: Hashable>(
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> [DiffableOutlineOperation<ItemID>] {
        snapshot.reloadIDs
            .filter { snapshot.contains($0) }
            .sorted { String(describing: $0) < String(describing: $1) }
            .map { DiffableOutlineOperation.reload(id: $0) }
    }

    private static func coveredIDs<ItemID: Hashable>(
        _ ids: Set<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> Set<ItemID> {
        var result = ids
        for id in ids {
            result.formUnion(snapshot.descendants(of: id))
        }
        return result
    }

    private static func parentIDsForSiblingDiff<ItemID: Hashable>(
        old: DiffableOutlineSnapshot<ItemID>,
        new: DiffableOutlineSnapshot<ItemID>
    ) -> [ItemID?] {
        var parentIDs: Set<ItemID?> = [nil]
        for (id, node) in old.nodes where !node.childIDs.isEmpty {
            parentIDs.insert(id)
        }
        for (id, node) in new.nodes where !node.childIDs.isEmpty {
            parentIDs.insert(id)
        }
        return parentIDs.sorted { lhs, rhs in
            String(describing: lhs) < String(describing: rhs)
        }
    }

    private static func sortedRemoves<ItemID: Hashable>(
        _ operations: [DiffableOutlineOperation<ItemID>],
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> [DiffableOutlineOperation<ItemID>] {
        operations.sorted { lhs, rhs in
            let left = removeSortKey(lhs, in: snapshot)
            let right = removeSortKey(rhs, in: snapshot)
            if left.depth != right.depth { return left.depth > right.depth }
            if left.parent != right.parent { return left.parent < right.parent }
            return left.index > right.index
        }
    }

    private static func sortedInserts<ItemID: Hashable>(
        _ operations: [DiffableOutlineOperation<ItemID>],
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> [DiffableOutlineOperation<ItemID>] {
        operations.sorted { lhs, rhs in
            let left = insertSortKey(lhs, in: snapshot)
            let right = insertSortKey(rhs, in: snapshot)
            if left.depth != right.depth { return left.depth < right.depth }
            if left.parent != right.parent { return left.parent < right.parent }
            return left.index < right.index
        }
    }

    private static func removeSortKey<ItemID: Hashable>(
        _ operation: DiffableOutlineOperation<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> (depth: Int, parent: String, index: Int) {
        guard case .remove(let id, let parentID, let index) = operation else {
            return (0, "", 0)
        }
        return (snapshot.depth(of: id), String(describing: parentID), index)
    }

    private static func insertSortKey<ItemID: Hashable>(
        _ operation: DiffableOutlineOperation<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> (depth: Int, parent: String, index: Int) {
        guard case .insert(let id, let parentID, let index) = operation else {
            return (0, "", 0)
        }
        return (snapshot.depth(of: id), String(describing: parentID), index)
    }

    private static func replacementSortKey<ItemID: Hashable>(
        _ operation: DiffableOutlineOperation<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> (depth: Int, parent: String, index: Int) {
        guard case .replace(let id, let parentID, let index) = operation else {
            return (0, "", 0)
        }
        return (snapshot.depth(of: id), String(describing: parentID), index)
    }
}

private struct DiffableOutlineStructuralOperations<ItemID: Hashable> {
    let removes: [DiffableOutlineOperation<ItemID>]
    let inserts: [DiffableOutlineOperation<ItemID>]
}

private extension CollectionDifference {
    var containsAssociatedMove: Bool {
        contains { change in
            switch change {
            case .insert(_, _, let associatedWith), .remove(_, _, let associatedWith):
                return associatedWith != nil
            }
        }
    }
}
