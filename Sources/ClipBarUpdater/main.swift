import Darwin
import Foundation
import Security

private struct UpdateArguments {
    let dmgURL: URL
    let destinationURL: URL
    let bundleIdentifier: String
    let expectedVersion: String
    let statusURL: URL
    let parentPID: pid_t

    init?(_ arguments: [String]) {
        guard arguments.count == 7,
              let parentPID = pid_t(arguments[6]),
              arguments[2] == "/Applications/ClipBar.app" else {
            return nil
        }
        dmgURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        destinationURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        bundleIdentifier = arguments[3]
        expectedVersion = arguments[4]
        statusURL = URL(fileURLWithPath: arguments[5]).standardizedFileURL
        self.parentPID = parentPID
    }
}

private struct InstallStatus: Codable {
    let succeeded: Bool
    let version: String
    let message: String
}

private enum UpdaterError: LocalizedError {
    case invalidArguments
    case invalidSource
    case parentDidNotExit
    case mountFailed(String)
    case appNotFound
    case invalidBundle
    case signatureFailed(String)
    case signingIdentityChanged

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "更新助手参数无效"
        case .invalidSource: return "更新文件不在 ClipBar 的更新目录中"
        case .parentDidNotExit: return "ClipBar 未能及时退出"
        case .mountFailed(let message): return "无法挂载更新镜像：\(message)"
        case .appNotFound: return "更新镜像中未找到 ClipBar.app"
        case .invalidBundle: return "更新包的应用标识或版本不匹配"
        case .signatureFailed(let message): return "更新包签名校验失败：\(message)"
        case .signingIdentityChanged: return "更新包签名身份与当前版本不一致"
        }
    }
}

private func runProcess(_ executable: String, arguments: [String]) throws -> (Int32, Data, Data) {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        stdout.fileHandleForReading.readDataToEndOfFile(),
        stderr.fileHandleForReading.readDataToEndOfFile()
    )
}

private func waitForParentToExit(_ pid: pid_t) throws {
    let deadline = Date().addingTimeInterval(30)
    while kill(pid, 0) == 0 {
        guard Date() < deadline else { throw UpdaterError.parentDidNotExit }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

private func mountDMG(_ url: URL) throws -> URL {
    let result = try runProcess(
        "/usr/bin/hdiutil",
        arguments: ["attach", "-readonly", "-nobrowse", "-plist", url.path]
    )
    guard result.0 == 0,
          let propertyList = try PropertyListSerialization.propertyList(
              from: result.1,
              options: [],
              format: nil
          ) as? [String: Any],
          let entities = propertyList["system-entities"] as? [[String: Any]],
          let mountPath = entities.compactMap({ $0["mount-point"] as? String }).last else {
        let message = String(data: result.2, encoding: .utf8) ?? "未知错误"
        throw UpdaterError.mountFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return URL(fileURLWithPath: mountPath, isDirectory: true)
}

private func staticCode(at appURL: URL) throws -> SecStaticCode {
    var code: SecStaticCode?
    let status = SecStaticCodeCreateWithPath(appURL as CFURL, [], &code)
    guard status == errSecSuccess, let code else {
        throw UpdaterError.signatureFailed(securityMessage(for: status))
    }
    return code
}

private func securityMessage(for status: OSStatus) -> String {
    SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
}

private func validateCandidate(
    _ candidateURL: URL,
    installedURL: URL,
    bundleIdentifier: String,
    expectedVersion: String
) throws {
    guard let bundle = Bundle(url: candidateURL),
          bundle.bundleIdentifier == bundleIdentifier,
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else {
        throw UpdaterError.invalidBundle
    }

    let installedCode = try staticCode(at: installedURL)
    var requirement: SecRequirement?
    let requirementStatus = SecCodeCopyDesignatedRequirement(installedCode, [], &requirement)
    guard requirementStatus == errSecSuccess, let requirement else {
        throw UpdaterError.signatureFailed(securityMessage(for: requirementStatus))
    }

    let candidateCode = try staticCode(at: candidateURL)
    let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
    let verificationStatus = SecStaticCodeCheckValidity(
        candidateCode,
        validationFlags,
        requirement
    )
    guard verificationStatus == errSecSuccess else {
        if verificationStatus == errSecCSReqFailed {
            throw UpdaterError.signingIdentityChanged
        }
        throw UpdaterError.signatureFailed(securityMessage(for: verificationStatus))
    }
}

private func installCandidate(_ sourceURL: URL, at destinationURL: URL) throws {
    let fileManager = FileManager.default
    let parentURL = destinationURL.deletingLastPathComponent()
    let token = UUID().uuidString
    let stagingURL = parentURL.appendingPathComponent(".ClipBar-update-\(token).app")
    let backupURL = parentURL.appendingPathComponent(".ClipBar-backup-\(token).app")

    try fileManager.copyItem(at: sourceURL, to: stagingURL)
    do {
        try fileManager.moveItem(at: destinationURL, to: backupURL)
        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            try? fileManager.moveItem(at: backupURL, to: destinationURL)
            throw error
        }
    } catch {
        try? fileManager.removeItem(at: stagingURL)
        throw error
    }
}

private func writeStatus(_ status: InstallStatus, to url: URL) {
    guard let data = try? JSONEncoder().encode(status) else { return }
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
}

private func relaunch(_ appURL: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [appURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

private func performUpdate(_ arguments: UpdateArguments) throws {
    guard let cachesDirectory = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
    ).first else {
        throw UpdaterError.invalidSource
    }
    let expectedDirectory = cachesDirectory
        .appendingPathComponent("ClipBarUpdates", isDirectory: true)
        .standardizedFileURL.path + "/"
    guard arguments.dmgURL.path.hasPrefix(expectedDirectory) else {
        throw UpdaterError.invalidSource
    }

    let mountURL = try mountDMG(arguments.dmgURL)
    defer {
        _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountURL.path])
    }
    let candidateURL = mountURL.appendingPathComponent("ClipBar.app", isDirectory: true)
    guard FileManager.default.fileExists(atPath: candidateURL.path) else {
        throw UpdaterError.appNotFound
    }
    try validateCandidate(
        candidateURL,
        installedURL: arguments.destinationURL,
        bundleIdentifier: arguments.bundleIdentifier,
        expectedVersion: arguments.expectedVersion
    )
    try waitForParentToExit(arguments.parentPID)
    try installCandidate(candidateURL, at: arguments.destinationURL)
    _ = try? runProcess(
        "/usr/bin/xattr",
        arguments: ["-dr", "com.apple.quarantine", arguments.destinationURL.path]
    )
}

guard let arguments = UpdateArguments(CommandLine.arguments) else {
    writeStatus(
        InstallStatus(succeeded: false, version: "", message: UpdaterError.invalidArguments.localizedDescription),
        to: URL(fileURLWithPath: "/tmp/ClipBarUpdater-status.json")
    )
    exit(2)
}

do {
    try performUpdate(arguments)
    try? FileManager.default.removeItem(at: arguments.dmgURL)
    writeStatus(
        InstallStatus(succeeded: true, version: arguments.expectedVersion, message: "更新安装完成"),
        to: arguments.statusURL
    )
    relaunch(arguments.destinationURL)
} catch {
    writeStatus(
        InstallStatus(succeeded: false, version: arguments.expectedVersion, message: error.localizedDescription),
        to: arguments.statusURL
    )
    relaunch(arguments.destinationURL)
    exit(1)
}
