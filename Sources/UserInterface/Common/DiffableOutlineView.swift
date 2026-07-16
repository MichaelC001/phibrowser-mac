// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

class DiffableOutlineView: NSOutlineView {
    private struct ReloadRequest {
        let snapshot: DiffableOutlineSnapshot<AnyHashable>
        let animated: Bool
        let debugLabel: String?
        let updateDataSource: () -> Void
        let prepareReloadData: (() -> Void)?
        let completion: (() -> Void)?
    }

    private var currentSnapshot: DiffableOutlineSnapshot<AnyHashable>?
    /// True only when `currentSnapshot` came from a request validated by this
    /// view. A snapshot injected through `resetDiffableSnapshot` deliberately
    /// remains untrusted so the checked planner preserves its fallback path.
    private var currentSnapshotIsValidated = false
    private var isApplyingSnapshot = false
    private var pendingReloadRequest: ReloadRequest?

    func reloadWith(
        _ snapshot: DiffableOutlineSnapshot<AnyHashable>,
        animated: Bool = true,
        debugLabel: String? = nil,
        updateDataSource: @escaping () -> Void,
        prepareReloadData: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        let request = ReloadRequest(
            snapshot: snapshot,
            animated: animated,
            debugLabel: debugLabel,
            updateDataSource: updateDataSource,
            prepareReloadData: prepareReloadData,
            completion: completion
        )

        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyOrQueue(request)
            }
            return
        }

        applyOrQueue(request)
    }

    private func applyOrQueue(_ request: ReloadRequest) {
        guard !isApplyingSnapshot else {
#if DEBUG
            logPerformance(
                request,
                "stage=diffable action=queued replacingPending=\(pendingReloadRequest != nil) " +
                "nodes=\(request.snapshot.nodes.count)"
            )
#endif
            pendingReloadRequest = request
            return
        }

        apply(request)
        applyPendingReloads()
    }

    private func applyPendingReloads() {
        while !isApplyingSnapshot, let request = pendingReloadRequest {
            pendingReloadRequest = nil
            apply(request)
        }
    }

    private func apply(_ request: ReloadRequest) {
#if DEBUG
        let totalStart = CFAbsoluteTimeGetCurrent()
        let validationStart = CFAbsoluteTimeGetCurrent()
#endif
        let validationError = request.snapshot.validationError
#if DEBUG
        let validationMs = (CFAbsoluteTimeGetCurrent() - validationStart) * 1000
#endif
        if let validationError {
#if DEBUG
            logPerformance(
                request,
                "stage=diffable mode=invalid nodes=\(request.snapshot.nodes.count) " +
                "validationMs=\(formatMilliseconds(validationMs)) " +
                "totalMs=\(formatMilliseconds((CFAbsoluteTimeGetCurrent() - totalStart) * 1000))"
            )
#endif
            reportInvalidSnapshot(validationError)
            request.completion?()
            return
        }

        guard let oldSnapshot = currentSnapshot else {
#if DEBUG
            let updateDataSourceStart = CFAbsoluteTimeGetCurrent()
#endif
            request.updateDataSource()
#if DEBUG
            let updateDataSourceMs = (CFAbsoluteTimeGetCurrent() - updateDataSourceStart) * 1000
            let reloadDataStart = CFAbsoluteTimeGetCurrent()
#endif
            request.prepareReloadData?()
            reloadData()
#if DEBUG
            let reloadDataMs = (CFAbsoluteTimeGetCurrent() - reloadDataStart) * 1000
#endif
            currentSnapshot = request.snapshot
            currentSnapshotIsValidated = true
#if DEBUG
            logPerformance(
                request,
                "stage=diffable mode=initial-reload nodes=\(request.snapshot.nodes.count) " +
                "validationMs=\(formatMilliseconds(validationMs)) " +
                "updateDataSourceMs=\(formatMilliseconds(updateDataSourceMs)) " +
                "reloadDataMs=\(formatMilliseconds(reloadDataMs)) " +
                "totalMs=\(formatMilliseconds((CFAbsoluteTimeGetCurrent() - totalStart) * 1000))"
            )
#endif
            request.completion?()
            return
        }

#if DEBUG
        let planStart = CFAbsoluteTimeGetCurrent()
#endif
        let plan: DiffableOutlinePlan<AnyHashable>
        if currentSnapshotIsValidated {
            plan = DiffableOutlineDiffPlanner.planValidated(
                from: oldSnapshot,
                to: request.snapshot,
                debugLabel: request.debugLabel
            )
        } else {
            plan = DiffableOutlineDiffPlanner.plan(
                from: oldSnapshot,
                to: request.snapshot,
                debugLabel: request.debugLabel
            )
        }
#if DEBUG
        let planMs = (CFAbsoluteTimeGetCurrent() - planStart) * 1000
#endif
        guard plan.isSafe else {
#if DEBUG
            let updateDataSourceStart = CFAbsoluteTimeGetCurrent()
#endif
            request.updateDataSource()
#if DEBUG
            let updateDataSourceMs = (CFAbsoluteTimeGetCurrent() - updateDataSourceStart) * 1000
            let reloadDataStart = CFAbsoluteTimeGetCurrent()
#endif
            request.prepareReloadData?()
            reloadData()
#if DEBUG
            let reloadDataMs = (CFAbsoluteTimeGetCurrent() - reloadDataStart) * 1000
#endif
            currentSnapshot = request.snapshot
            currentSnapshotIsValidated = true
#if DEBUG
            logPerformance(
                request,
                "stage=diffable mode=unsafe-reload oldNodes=\(oldSnapshot.nodes.count) " +
                "newNodes=\(request.snapshot.nodes.count) validationMs=\(formatMilliseconds(validationMs)) " +
                "planMs=\(formatMilliseconds(planMs)) " +
                "updateDataSourceMs=\(formatMilliseconds(updateDataSourceMs)) " +
                "reloadDataMs=\(formatMilliseconds(reloadDataMs)) " +
                "totalMs=\(formatMilliseconds((CFAbsoluteTimeGetCurrent() - totalStart) * 1000))"
            )
#endif
            request.completion?()
            return
        }

        isApplyingSnapshot = true
#if DEBUG
        let updateDataSourceStart = CFAbsoluteTimeGetCurrent()
#endif
        request.updateDataSource()
#if DEBUG
        let updateDataSourceMs = (CFAbsoluteTimeGetCurrent() - updateDataSourceStart) * 1000
        let applyStart = CFAbsoluteTimeGetCurrent()
#endif
        apply(plan.operations, oldSnapshot: oldSnapshot, newSnapshot: request.snapshot, animated: request.animated)
#if DEBUG
        let applyMs = (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
#endif
        currentSnapshot = request.snapshot
        currentSnapshotIsValidated = true
        isApplyingSnapshot = false

#if DEBUG
        logPerformance(
            request,
            "stage=diffable mode=incremental oldNodes=\(oldSnapshot.nodes.count) " +
            "newNodes=\(request.snapshot.nodes.count) operations=\(plan.operations.count) " +
            "validationMs=\(formatMilliseconds(validationMs)) planMs=\(formatMilliseconds(planMs)) " +
            "updateDataSourceMs=\(formatMilliseconds(updateDataSourceMs)) " +
            "appKitApplyMs=\(formatMilliseconds(applyMs)) " +
            "totalMs=\(formatMilliseconds((CFAbsoluteTimeGetCurrent() - totalStart) * 1000))"
        )
#endif
        DispatchQueue.main.async {
            request.completion?()
        }
    }

#if DEBUG
    private func logPerformance(_ request: ReloadRequest, _ details: String) {
        guard let debugLabel = request.debugLabel else { return }
        AppLogDebug("[PHI_DEBUG][PIN_CLICK][BM][SIDEBAR_REFRESH] \(debugLabel) \(details)")
    }

    private func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
#endif

    func resetDiffableSnapshot(_ snapshot: DiffableOutlineSnapshot<AnyHashable>? = nil) {
        currentSnapshot = snapshot
        currentSnapshotIsValidated = false
    }

    func reportInvalidSnapshot(_ error: DiffableOutlineSnapshotValidationError<AnyHashable>) {
        AppLogWarn("[DiffableOutlineView] invalid snapshot: \(error)")
#if DEBUG
        assertionFailure("Invalid DiffableOutlineSnapshot: \(error)")
#endif
    }

    func applyRemove(
        at indexes: IndexSet,
        inParent parent: Any?,
        animation: NSOutlineView.AnimationOptions
    ) {
        removeItems(at: indexes, inParent: parent, withAnimation: animation)
    }

    func applyInsert(
        at indexes: IndexSet,
        inParent parent: Any?,
        animation: NSOutlineView.AnimationOptions
    ) {
        insertItems(at: indexes, inParent: parent, withAnimation: animation)
    }

    func applyMove(
        from fromIndex: Int,
        inParent oldParent: Any?,
        to toIndex: Int,
        inParent newParent: Any?
    ) {
        moveItem(at: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    func applyReload(rowIndexes: IndexSet) {
        guard !rowIndexes.isEmpty, numberOfColumns > 0 else { return }
        reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
    }

    private func apply(
        _ operations: [DiffableOutlineOperation<AnyHashable>],
        oldSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        newSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        animated: Bool
    ) {
        guard !operations.isEmpty else { return }

        let animation: NSOutlineView.AnimationOptions = animated ? [.effectFade, .effectGap] : []
        beginUpdates()
        for operation in operations {
            apply(
                operation,
                oldSnapshot: oldSnapshot,
                newSnapshot: newSnapshot,
                animation: animation
            )
        }
        endUpdates()
    }

    private func apply(
        _ operation: DiffableOutlineOperation<AnyHashable>,
        oldSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        newSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        animation: NSOutlineView.AnimationOptions
    ) {
        switch operation {
        case .remove(_, let parentID, let index):
            applyRemove(
                at: IndexSet(integer: index),
                inParent: oldSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
        case .move(_, let parentID, let from, let to):
            let parent = oldSnapshot.item(forOptionalID: parentID)
            applyMove(from: from, inParent: parent, to: to, inParent: parent)
        case .insert(_, let parentID, let index):
            applyInsert(
                at: IndexSet(integer: index),
                inParent: newSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
        case .replace(_, let parentID, let index):
            applyRemove(
                at: IndexSet(integer: index),
                inParent: oldSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
            applyInsert(
                at: IndexSet(integer: index),
                inParent: newSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
        case .reload(let id):
            guard let item = newSnapshot.item(for: id) else { return }
            let row = row(forItem: item)
            guard row >= 0 else { return }
            applyReload(rowIndexes: IndexSet(integer: row))
        }
    }
}

private extension DiffableOutlineSnapshot where ItemID == AnyHashable {
    func item(forOptionalID id: ItemID?) -> AnyObject? {
        guard let id else { return nil }
        return item(for: id)
    }
}
