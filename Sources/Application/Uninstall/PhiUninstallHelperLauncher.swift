// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation

struct PreparedPhiUninstaller: Equatable, Sendable {
    let workingDirectoryURL: URL
    let executableURL: URL
    let planURL: URL
}

enum PhiUninstallHelperLauncherError: Error, LocalizedError {
    case helperUnavailable(URL)
    case helperNotExecutable(URL)
    case helperReadinessTimedOut
    case helperExitedBeforeReady
    case invalidHelperReadinessSignal
    case helperReadinessCheckFailed(Int32)
    case helperCommitTimedOut
    case helperExitedBeforeCommit
    case invalidHelperCommitSignal
    case helperCommitCheckFailed(Int32)
    case helperCommitWriteFailed

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let url):
            return "The Phi uninstaller helper is unavailable at \(url.path)."
        case .helperNotExecutable(let url):
            return "The Phi uninstaller helper is not executable at \(url.path)."
        case .helperReadinessTimedOut:
            return "The Phi uninstaller helper did not become ready in time."
        case .helperExitedBeforeReady:
            return "The Phi uninstaller helper exited before it became ready."
        case .invalidHelperReadinessSignal:
            return "The Phi uninstaller helper returned an invalid readiness signal."
        case .helperReadinessCheckFailed(let errorNumber):
            return "The Phi uninstaller helper readiness check failed with errno \(errorNumber)."
        case .helperCommitTimedOut:
            return "The Phi uninstaller helper did not accept the uninstall commit in time."
        case .helperExitedBeforeCommit:
            return "The Phi uninstaller helper exited before accepting the uninstall commit."
        case .invalidHelperCommitSignal:
            return "The Phi uninstaller helper returned an invalid commit signal."
        case .helperCommitCheckFailed(let errorNumber):
            return "The Phi uninstaller helper commit check failed with errno \(errorNumber)."
        case .helperCommitWriteFailed:
            return "Phi could not send the uninstall commit to the helper."
        }
    }
}

final class RunningPhiUninstaller {
    private var commitAction: (() throws -> Void)?
    private var cancellation: (() -> Void)?

    init(
        commit: @escaping () throws -> Void = {},
        cancel: @escaping () -> Void
    ) {
        commitAction = commit
        cancellation = cancel
    }

    func commit() throws {
        guard let commitAction else { return }
        do {
            try commitAction()
            self.commitAction = nil
            cancellation = nil
        } catch {
            self.commitAction = nil
            cancel()
            throw error
        }
    }

    func cancel() {
        commitAction = nil
        let cancellation = cancellation
        self.cancellation = nil
        cancellation?()
    }

    deinit {
        cancel()
    }
}

enum PhiUninstallHelperLauncher {
    static let helperFilename = PhiUninstallPreparedWorkspace.helperFilename
    static let planFilename = PhiUninstallPreparedWorkspace.planFilename

    static func prepare(
        plan: PhiUninstallPlan,
        appBundleURL: URL = Bundle.main.bundleURL,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> PreparedPhiUninstaller {
        let sourceURL = appBundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(helperFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PhiUninstallHelperLauncherError.helperUnavailable(sourceURL)
        }

        let workingDirectoryURL = temporaryDirectoryURL.appendingPathComponent(
            "\(PhiUninstallPreparedWorkspace.directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let executableURL = workingDirectoryURL
                .appendingPathComponent(helperFilename, isDirectory: false)
            try fileManager.copyItem(at: sourceURL, to: executableURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
            guard fileManager.isExecutableFile(atPath: executableURL.path) else {
                throw PhiUninstallHelperLauncherError.helperNotExecutable(executableURL)
            }

            let planURL = workingDirectoryURL
                .appendingPathComponent(planFilename, isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(plan).write(to: planURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: planURL.path)

            _ = try PhiUninstallPreparedWorkspace.validate(
                planURL: planURL,
                executableURL: executableURL,
                temporaryDirectoryURL: temporaryDirectoryURL,
                fileManager: fileManager
            )

            return PreparedPhiUninstaller(
                workingDirectoryURL: workingDirectoryURL,
                executableURL: executableURL,
                planURL: planURL
            )
        } catch {
            try? fileManager.removeItem(at: workingDirectoryURL)
            throw error
        }
    }

    static func launch(
        _ prepared: PreparedPhiUninstaller,
        readinessTimeout: TimeInterval = PhiUninstallReadiness.timeout
    ) throws -> RunningPhiUninstaller {
        let process = Process()
        let readinessPipe = Pipe()
        let commitPipe = Pipe()
        process.executableURL = prepared.executableURL
        process.arguments = ["--plan", prepared.planURL.path]
        process.standardInput = commitPipe
        process.standardOutput = readinessPipe
        process.standardError = FileHandle.nullDevice
        _ = Darwin.fcntl(
            commitPipe.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        )
        do {
            try process.run()
        } catch {
            commitPipe.fileHandleForReading.closeFile()
            commitPipe.fileHandleForWriting.closeFile()
            readinessPipe.fileHandleForReading.closeFile()
            readinessPipe.fileHandleForWriting.closeFile()
            throw error
        }
        commitPipe.fileHandleForReading.closeFile()
        readinessPipe.fileHandleForWriting.closeFile()

        do {
            try waitForSignal(
                fileDescriptor: readinessPipe.fileHandleForReading.fileDescriptor,
                expected: Data(PhiUninstallReadiness.readyToken.utf8),
                timeout: readinessTimeout,
                phase: .readiness
            )
            return RunningPhiUninstaller(
                commit: {
                    do {
                        try commitPipe.fileHandleForWriting.write(
                            contentsOf: Data(PhiUninstallReadiness.commitToken.utf8)
                        )
                    } catch {
                        throw PhiUninstallHelperLauncherError.helperCommitWriteFailed
                    }
                    commitPipe.fileHandleForWriting.closeFile()
                    try waitForSignal(
                        fileDescriptor: readinessPipe.fileHandleForReading.fileDescriptor,
                        expected: Data(PhiUninstallReadiness.committedToken.utf8),
                        timeout: readinessTimeout,
                        phase: .commit
                    )
                    readinessPipe.fileHandleForReading.closeFile()
                },
                cancel: {
                    commitPipe.fileHandleForWriting.closeFile()
                    readinessPipe.fileHandleForReading.closeFile()
                    terminate(process)
                }
            )
        } catch {
            // Close first so a delayed ACK cannot cross the commit barrier after
            // the coordinator has restored Sentinel and returned to the UI.
            commitPipe.fileHandleForWriting.closeFile()
            readinessPipe.fileHandleForReading.closeFile()
            terminate(process)
            throw error
        }
    }

    static func cleanup(
        _ prepared: PreparedPhiUninstaller,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: prepared.workingDirectoryURL)
    }

    private enum SignalPhase {
        case readiness
        case commit
    }

    private static func waitForSignal(
        fileDescriptor: Int32,
        expected: Data,
        timeout: TimeInterval,
        phase: SignalPhase
    ) throws {
        var received = Data()
        let deadline = Date().addingTimeInterval(max(0, timeout))

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw timeoutError(for: phase)
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
            let result = Darwin.poll(&descriptor, 1, max(1, milliseconds))
            if result == 0 {
                throw timeoutError(for: phase)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw checkError(for: phase, errorNumber: errno)
            }
            if descriptor.revents & Int16(POLLNVAL | POLLERR) != 0 {
                throw checkError(for: phase, errorNumber: EIO)
            }

            var buffer = [UInt8](repeating: 0, count: expected.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 {
                throw exitError(for: phase)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw checkError(for: phase, errorNumber: errno)
            }

            received.append(contentsOf: buffer.prefix(count))
            guard received.count <= expected.count, expected.starts(with: received) else {
                throw invalidSignalError(for: phase)
            }
            if received == expected {
                return
            }
        }
    }

    private static func timeoutError(
        for phase: SignalPhase
    ) -> PhiUninstallHelperLauncherError {
        switch phase {
        case .readiness: return .helperReadinessTimedOut
        case .commit: return .helperCommitTimedOut
        }
    }

    private static func exitError(
        for phase: SignalPhase
    ) -> PhiUninstallHelperLauncherError {
        switch phase {
        case .readiness: return .helperExitedBeforeReady
        case .commit: return .helperExitedBeforeCommit
        }
    }

    private static func invalidSignalError(
        for phase: SignalPhase
    ) -> PhiUninstallHelperLauncherError {
        switch phase {
        case .readiness: return .invalidHelperReadinessSignal
        case .commit: return .invalidHelperCommitSignal
        }
    }

    private static func checkError(
        for phase: SignalPhase,
        errorNumber: Int32
    ) -> PhiUninstallHelperLauncherError {
        switch phase {
        case .readiness: return .helperReadinessCheckFailed(errorNumber)
        case .commit: return .helperCommitCheckFailed(errorNumber)
        }
    }

    fileprivate static func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()

            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }
}
