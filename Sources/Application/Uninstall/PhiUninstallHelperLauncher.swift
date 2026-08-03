// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct PreparedPhiUninstaller: Equatable, Sendable {
    let workingDirectoryURL: URL
    let executableURL: URL
    let planURL: URL
}

enum PhiUninstallHelperLauncherError: Error, LocalizedError {
    case helperUnavailable(URL)
    case helperNotExecutable(URL)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let url):
            return "The Phi uninstaller helper is unavailable at \(url.path)."
        case .helperNotExecutable(let url):
            return "The Phi uninstaller helper is not executable at \(url.path)."
        }
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

    static func launch(_ prepared: PreparedPhiUninstaller) throws {
        let process = Process()
        process.executableURL = prepared.executableURL
        process.arguments = ["--plan", prepared.planURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func cleanup(
        _ prepared: PreparedPhiUninstaller,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: prepared.workingDirectoryURL)
    }
}
