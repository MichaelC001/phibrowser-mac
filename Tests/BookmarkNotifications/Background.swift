// Actual production ModelActor constructed on a GCD worker. Returning the actor
// crosses an actor reference, never its ModelContext or any persistent model.
extension Evidence {
    static func makeWorker(_ container: ModelContainer) async -> LocalStoreActor {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                check(!Thread.isMainThread, "ModelActor construction must run off main")
                continuation.resume(returning: LocalStoreActor(modelContainer: container))
            }
        }
    }

    @MainActor static func checkBackgroundWrites() async throws {
        let seeded = try await store("background.sqlite")
        let writer = await makeWorker(seeded.container)
        let writerWasMain = try await writer.performThrowing { _ in Thread.isMainThread }
        check(!writerWasMain, "production ModelActor executor must actually save off main")
        let primary = LocalStore(seeded.container, suppliedWriter: writer)
        let receivers = [Receiver(primary, profile: "A", space: "S", name: "A/S"),
            Receiver(primary, profile: "A", space: "T", name: "A/T")]
        let recorder = SaveRecorder()
        receivers.forEach { $0.callbacks = 0; $0.metadataCallbacks = 0 }
        primary.mainContext!.fetches = 0
        primary.updateLastSeen("a-s", seenAt: Date(timeIntervalSince1970: 1001))
        await drain(primary)
        let events = recorder.snapshot()
        print("BACKGROUND_PROBE " + String(data: try JSONSerialization.data(withJSONObject: events, options: .sortedKeys), encoding: .utf8)!)
        check(!events.isEmpty && events.allSatisfy { $0["on_main_thread"] as? Bool == false }, "real save notifications must run off main")
        check(receivers[0].projection.bookmarkIndex["a-s"]?.lastSeen?.timeIntervalSince1970 == 1001,
              "background visit must update main-context projection")
        check(receivers[0].metadataCallbacks == 1 && receivers[0].callbacks == 0 && receivers[1].metadataCallbacks == 0,
              "background visit must only deliver one metadata update")
        check(receivers.allSatisfy(\.allCallbacksOnMainThread) && primary.mainContext!.allFetchesOnMainThread,
              "all UI reads and deliveries must execute on main")
        print("PASS: confirmed off-main ModelActor save and notification, main query and indexed date delivery")

        let secondWriter = await makeWorker(seeded.container)
        let second = LocalStore(seeded.container, suppliedWriter: secondWriter)
        recorder.reset()
        receivers.forEach { $0.callbacks = 0; $0.metadataCallbacks = 0 }
        primary.mainContext!.fetches = 0
        for index in 0..<20 {
            primary.updateLastSeen("a-s", seenAt: Date(timeIntervalSince1970: Double(1100 + index)))
            second.updateLastSeen("a-t", seenAt: Date(timeIntervalSince1970: Double(2100 + index)))
        }
        await drain(primary); await drain(second)
        check(recorder.snapshot().count == 40, "two writers must complete 40 actual saves")
        check(Set(recorder.snapshot().compactMap { $0["context_id"] as? String }).count == 2,
              "interleaving must use two distinct Core Data contexts")
        check(recorder.snapshot().allSatisfy { $0["private_queue_context"] as? Bool == true },
              "both writers must use private-queue contexts")
        check(recorder.snapshot().allSatisfy { $0["on_main_thread"] as? Bool == false }, "both writers must notify off main")
        check(receivers[0].metadataCallbacks == 20 && receivers[1].metadataCallbacks == 20 && receivers.allSatisfy { $0.callbacks == 0 },
              "interleaved contexts must not lose or misclassify visit evidence")
        check(receivers[0].projection.bookmarkIndex["a-s"]?.lastSeen?.timeIntervalSince1970 == 1119
            && receivers[1].projection.bookmarkIndex["a-t"]?.lastSeen?.timeIntervalSince1970 == 2119,
              "both main-context projections must finish with the latest saved visit")
        check(primary.mainContext!.fetches == 40, "40 visits must use 40 targeted reads, not full trees")
        print("PASS: two private writer contexts, 40 interleaved saves, 40 targeted main reads, latest dates preserved")

        recorder.reset()
        receivers.forEach { $0.callbacks = 0; $0.metadataCallbacks = 0 }
        for index in 0..<20 {
            primary.updateLastSeen("a-s", seenAt: Date(timeIntervalSince1970: Double(2200 + index)))
            second.performBackgroundWrite { context in
                let guid = "a-t"
                let row = try! context.fetch(FetchDescriptor<TabDataModel>(predicate: #Predicate { $0.guid == guid })).first!
                row.title = "Mixed writer \(index)"
                row.lastSeen = Date(timeIntervalSince1970: Double(2300 + index))
            }
        }
        await drain(primary); await drain(second)
        check(recorder.snapshot().count == 40 && recorder.snapshot().allSatisfy { $0["on_main_thread"] as? Bool == false },
              "mixed contexts must finish 40 off-main saves")
        check(receivers.allSatisfy { $0.callbacks == 20 } && receivers[0].metadataCallbacks == 20 && receivers[1].metadataCallbacks == 0,
              "one context's structural evidence must not overwrite another context's visit evidence")
        check(receivers[1].lastValues["a-t"]?["title"] as? String == "Mixed writer 19",
              "interleaved structural updates must reach the final title")
        print("PASS: 40 interleaved structural/visit saves retain separate context evidence")

        // Explicitly sequence different contexts writing the same row. Their cached
        // models must not cause the UI projection to miss a later successful write.
        for index in 0..<6 {
            let store = index.isMultiple(of: 2) ? primary : second
            store.updateLastSeen("a-s", seenAt: Date(timeIntervalSince1970: Double(3000 + index)))
            await drain(store)
            check(receivers[0].projection.bookmarkIndex["a-s"]?.lastSeen?.timeIntervalSince1970 == Double(3000 + index),
                  "same-GUID writes from alternating contexts must remain fresh")
        }
        print("PASS: six alternating-context writes to the same GUID")

        recorder.reset()
        receivers.forEach { $0.callbacks = 0; $0.metadataCallbacks = 0 }
        var injector: SaveFailureInjector? = SaveFailureInjector(guid: "a-s")
        primary.performBackgroundWrite { context in
            check(!Thread.isMainThread, "failed write must execute on the background writer")
            let guid = "a-s"
            let row = try! context.fetch(FetchDescriptor<TabDataModel>(predicate: #Predicate { $0.guid == guid })).first!
            row.title = "Must not commit"
            row.lastSeen = Date(timeIntervalSince1970: 4000)
        }
        await drain(primary)
        check(injector?.didFire == true, "validation failure must actually be injected")
        injector = nil
        check(recorder.snapshot().isEmpty && receivers.allSatisfy { $0.callbacks == 0 && $0.metadataCallbacks == 0 },
              "failed save must not publish any tree or visit update")
        primary.updateLastSeen("a-s", seenAt: Date(timeIntervalSince1970: 4001))
        await drain(primary)
        check(receivers[0].metadataCallbacks == 1 && receivers[0].callbacks == 0,
              "rollback must not leave stale structural evidence on the next successful visit")
        check(receivers[0].projection.bookmarkIndex["a-s"]?.lastSeen?.timeIntervalSince1970 == 4001,
              "writer must remain usable after failed save and rollback")
        print("PASS: actual failed background save emitted nothing; rollback and next metadata-only save recovered")

        receivers.forEach { $0.callbacks = 0; $0.metadataCallbacks = 0 }
        primary.mainContext!.failNextFetch = true
        second.updateLastSeen("a-s", seenAt: Date(timeIntervalSince1970: 4002))
        await drain(second)
        check(receivers[0].callbacks == 1 && receivers[0].projection.bookmarkIndex["a-s"]?.lastSeen?.timeIntervalSince1970 == 4002,
              "background metadata must recover from a main targeted-fetch failure")

        // Block only this hostless test's main thread briefly: the worker finishes
        // its real save while the Combine main-queue delivery is still queued.
        let saved = DispatchSemaphore(value: 0)
        Task.detached {
            try! await writer.performThrowing { context in
                let guid = "a-s"
                let row = try context.fetch(FetchDescriptor<TabDataModel>(predicate: #Predicate { $0.guid == guid })).first!
                row.lastSeen = Date(timeIntervalSince1970: 5000)
            }
            saved.signal()
        }
        check(saved.wait(timeout: .now() + 5) == .success, "background save must complete without main execution")
        receivers[0].subscription?.cancel()
        let query = primary.mainContext!
        query.fetches = 0
        receivers[0].callbacks = 0; receivers[0].metadataCallbacks = 0
        await drain(primary)
        check(query.fetches == 0 && receivers[0].callbacks == 0 && receivers[0].metadataCallbacks == 0,
              "cancellation must discard an already queued metadata delivery")

        let closed = DispatchSemaphore(value: 0)
        Task.detached {
            try! await secondWriter.performThrowing { context in
                let guid = "a-t"
                let row = try context.fetch(FetchDescriptor<TabDataModel>(predicate: #Predicate { $0.guid == guid })).first!
                row.lastSeen = Date(timeIntervalSince1970: 5001)
            }
            closed.signal()
        }
        check(closed.wait(timeout: .now() + 5) == .success, "second background save must complete independently")
        primary.mainContext = nil
        query.fetches = 0
        receivers[1].callbacks = 0; receivers[1].metadataCallbacks = 0
        await drain(second)
        check(query.fetches == 0 && receivers[1].callbacks == 0 && receivers[1].metadataCallbacks == 0,
              "store closure must discard queued background delivery without reading released context")
        receivers[1].subscription?.cancel()
        check(receivers.allSatisfy(\.allCallbacksOnMainThread) && query.allFetchesOnMainThread,
              "no background managed object or UI context may escape its execution queue")
        print("PASS: background fetch fallback, cancellation and store closure discard queued deliveries")
    }
}

// A deliberate invalid required attribute makes a real SQLite-backed save fail.
// The object is touched only inside its synchronous willSave callback on its queue.
private final class SaveFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var observer: NSObjectProtocol?
    init(guid: String) {
        observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextWillSave,
            object: nil, queue: nil) { [weak self] notification in
                guard let self, let context = notification.object as? NSManagedObjectContext else { return }
                for object in context.updatedObjects where object.entity.name == TabDataModel.entityName {
                    guard object.value(forKey: "guid") as? String == guid else { continue }
                    self.lock.lock()
                    let shouldFail = !self.fired
                    self.fired = true
                    self.lock.unlock()
                    if shouldFail { object.setValue(nil, forKey: "title") }
                }
            }
    }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
