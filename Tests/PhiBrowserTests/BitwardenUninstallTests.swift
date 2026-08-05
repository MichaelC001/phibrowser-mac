// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Security
import XCTest
@testable import Phi

final class BitwardenUninstallTests: XCTestCase {
    func testPersistenceFenceWaitsForInFlightWriteAndRejectsLateWrite() {
        let gate = BitwardenSessionPersistenceGate()
        let saveStarted = DispatchSemaphore(value: 0)
        let releaseSave = DispatchSemaphore(value: 0)
        let fenceCompleted = DispatchSemaphore(value: 0)
        var events: [String] = []

        DispatchQueue.global().async {
            gate.performIfEnabled {
                saveStarted.signal()
                releaseSave.wait()
                events.append("save")
            }
        }
        XCTAssertEqual(saveStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            gate.fence()
            gate.performExclusive {
                events.append("clear")
            }
            fenceCompleted.signal()
        }
        XCTAssertEqual(fenceCompleted.wait(timeout: .now() + 0.05), .timedOut)

        releaseSave.signal()
        XCTAssertEqual(fenceCompleted.wait(timeout: .now() + 1), .success)
        gate.performIfEnabled {
            events.append("lateSave")
        }

        XCTAssertEqual(events, ["save", "clear"])
    }

    func testStrictClearAcceptsMissingItem() {
        XCTAssertNoThrow(try BitwardenSessionStore.clearAndVerifyForUninstall(
            deleteItem: { errSecItemNotFound },
            itemStatus: { errSecItemNotFound },
            retryDelay: {}
        ))
    }

    func testStrictClearRetriesTransientDeleteFailure() {
        var deleteStatuses: [OSStatus] = [errSecInternalComponent, errSecSuccess]
        var retryCount = 0

        XCTAssertNoThrow(try BitwardenSessionStore.clearAndVerifyForUninstall(
            deleteItem: { deleteStatuses.removeFirst() },
            itemStatus: { errSecItemNotFound },
            retryDelay: { retryCount += 1 }
        ))
        XCTAssertEqual(retryCount, 1)
        XCTAssertTrue(deleteStatuses.isEmpty)
    }

    func testStrictClearReportsDeleteFailure() {
        XCTAssertThrowsError(try BitwardenSessionStore.clearAndVerifyForUninstall(
            deleteItem: { errSecAuthFailed },
            itemStatus: { errSecSuccess },
            retryDelay: {}
        )) { error in
            XCTAssertEqual(
                error as? BitwardenSessionStoreUninstallError,
                .deletionFailed(errSecAuthFailed)
            )
        }
    }

    func testStrictClearRetriesItemThatIsStillPresent() {
        var itemStatuses: [OSStatus] = [errSecSuccess, errSecItemNotFound]
        var deleteCount = 0

        XCTAssertNoThrow(try BitwardenSessionStore.clearAndVerifyForUninstall(
            deleteItem: {
                deleteCount += 1
                return errSecSuccess
            },
            itemStatus: { itemStatuses.removeFirst() },
            retryDelay: {}
        ))
        XCTAssertEqual(deleteCount, 2)
        XCTAssertTrue(itemStatuses.isEmpty)
    }

    func testStrictClearReportsVerificationFailure() {
        XCTAssertThrowsError(try BitwardenSessionStore.clearAndVerifyForUninstall(
            deleteItem: { errSecSuccess },
            itemStatus: { errSecInteractionNotAllowed },
            retryDelay: {}
        )) { error in
            XCTAssertEqual(
                error as? BitwardenSessionStoreUninstallError,
                .verificationFailed(errSecInteractionNotAllowed)
            )
        }
    }

    func testClientShutdownIsIdempotentAndRejectsNewRequests() async {
        let client = BitwardenHelperClient()

        await client.shutdownForUninstall()
        await client.shutdownForUninstall()

        do {
            _ = try await client.send(method: "status", params: [:])
            XCTFail("Expected a shutting-down error")
        } catch {
            XCTAssertEqual(error as? BitwardenHelperClient.ClientError, .shuttingDown)
        }
    }

    func testUninstallShutdownForceKillsHelperThatIgnoresTermination() throws {
        let process = Process()
        let readinessPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "trap '' TERM; printf ready; while :; do :; done",
        ]
        process.standardOutput = readinessPipe
        try process.run()
        readinessPipe.fileHandleForWriting.closeFile()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        XCTAssertEqual(
            readinessPipe.fileHandleForReading.readData(ofLength: 5),
            Data("ready".utf8)
        )
        BitwardenHelperClient.terminateProcessForUninstall(process, timeout: 0.05)

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }
}
