import AppKit
import ClipboardManagerCore
import Foundation

/// 检查 GitHub Release，优先镜像下载 pkg，校验后打开安装器并退出。
@MainActor
enum UpdateChecker {
    private static let owner = "BaaKoo9"
    private static let repo = "ClipBar"
    private static let latestPageURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    private static let userAgent = "ClipBar/\(currentVersion) (+https://github.com/\(owner)/\(repo))"

    /// 国内直连 github.com 常超时；镜像实测可用（ghfast ~4s 下完 2.3MB）。
    private static let downloadMirrors = [
        "https://ghfast.top/",
        "https://ghproxy.net/",
    ]

    private struct ReleaseInfo {
        let tagName: String
        let htmlURL: String
        let body: String?
        let pkgName: String
        let expectedSize: Int64?
        let downloadURLs: [URL]
    }

    private struct APIRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    private struct Asset: Decodable {
        let id: Int64
        let name: String
        let size: Int64
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case size
            case browserDownloadURL = "browser_download_url"
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `interactive == false` 时静默写入设置；`true` 时走进度条下载并自动打开安装器。
    static func checkForUpdates(interactive: Bool = true) {
        let progress = UpdateProgressModel.shared
        DebugLog.write("检查更新：当前版本 \(currentVersion) interactive=\(interactive)")
        if interactive {
            progress.phase = .checking
            progress.fractionCompleted = 0
            progress.statusText = "正在检查更新…"
        }

        Task {
            do {
                let release = try await fetchLatestRelease(preferAPI: true)
                let remote = normalizeVersion(release.tagName)
                let local = normalizeVersion(currentVersion)
                AppSettings.shared.lastUpdateCheckAt = Date().timeIntervalSince1970
                NotificationCenter.default.post(name: .clipboardUpdateAvailable, object: nil)
                DebugLog.write(
                    "检查更新：远程 \(remote) 本地 \(local) pkg=\(release.pkgName) " +
                    "urls=\(release.downloadURLs.count) size=\(release.expectedSize ?? -1)"
                )

                if compareVersion(remote, local) <= 0 {
                    AppSettings.shared.availableUpdateVersion = nil
                    NotificationCenter.default.post(name: .clipboardUpdateAvailable, object: nil)
                    if interactive {
                        progress.reset()
                        presentAlert(
                            title: "已是最新版本",
                            message: "当前版本 \(currentVersion)，无需更新。",
                            style: .informational
                        )
                    }
                    return
                }

                AppSettings.shared.availableUpdateVersion = remote
                NotificationCenter.default.post(name: .clipboardUpdateAvailable, object: nil)

                guard interactive else {
                    DebugLog.write("检查更新：静默发现 \(remote)")
                    return
                }

                guard !release.downloadURLs.isEmpty else {
                    progress.phase = .failed("未找到安装包")
                    presentAlert(
                        title: "发现新版本 \(remote)",
                        message: "未找到可下载的安装包。可稍后重试，或到 Releases 手动下载。",
                        style: .warning,
                        openURL: URL(string: release.htmlURL)
                    )
                    return
                }

                let go = confirmUpdate(version: remote, notes: release.body)
                guard go else {
                    AppSettings.shared.dismissedUpdateVersion = remote
                    NotificationCenter.default.post(name: .clipboardUpdateAvailable, object: nil)
                    progress.reset()
                    return
                }

                try await performDownloadAndInstall(release: release, remote: remote)
            } catch {
                DebugLog.write("检查更新失败：\(error.localizedDescription)")
                if interactive {
                    UpdateProgressModel.shared.phase = .failed(error.localizedDescription)
                    presentAlert(
                        title: "更新失败",
                        message: error.localizedDescription + "\n\n可点击「立即检查更新」重试。",
                        style: .warning
                    )
                }
            }
        }
    }

    private static func performDownloadAndInstall(release: ReleaseInfo, remote: String) async throws {
        let progress = UpdateProgressModel.shared
        progress.phase = .downloading
        progress.fractionCompleted = 0
        progress.statusText = "正在下载 \(remote)…"

        let pkgURL = try await downloadWithProgress(
            urls: release.downloadURLs,
            named: release.pkgName,
            expectedSize: release.expectedSize
        )
        DebugLog.write("检查更新：已下载 \(pkgURL.path) (\(fileSize(pkgURL)) bytes)")

        progress.phase = .installing
        progress.fractionCompleted = 1
        progress.statusText = "准备安装并重启…"

        // 打开系统安装器；退出本进程以便覆盖 /Applications/ClipBar.app
        // postinstall 会在安装结束后自动拉起新版本
        NSWorkspace.shared.open(pkgURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NSApp.terminate(nil)
        }
    }

    static func schedulePeriodicChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            runSilentIfDue()
        }
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in
                runSilentIfDue()
            }
        }
    }

    private static func runSilentIfDue() {
        let last = AppSettings.shared.lastUpdateCheckAt
        let due = last <= 0 || Date().timeIntervalSince1970 - last >= 24 * 60 * 60
        guard due else { return }
        checkForUpdates(interactive: false)
    }

    // MARK: - Network

    private static func fetchLatestRelease(preferAPI: Bool) async throws -> ReleaseInfo {
        if preferAPI, let api = try? await fetchViaAPI() {
            return api
        }
        if let web = try? await fetchViaRedirect() {
            return web
        }
        return try await fetchViaAPI()
    }

    private static func fetchViaRedirect() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestPageURL)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url,
              let tag = extractTag(from: url) else {
            throw UpdateError.parseFailed
        }
        let version = normalizeVersion(tag)
        let pkgName = "ClipBar-\(version).pkg"
        let direct = pkgCandidateURLs(version: version, tag: tag)
        return ReleaseInfo(
            tagName: tag,
            htmlURL: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)",
            body: nil,
            pkgName: pkgName,
            expectedSize: nil,
            downloadURLs: prioritizedDownloadURLs(direct)
        )
    }

    private static func fetchViaAPI() async throws -> ReleaseInfo {
        var request = URLRequest(url: apiURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            throw UpdateError.http(http.statusCode, rateLimited: remaining == "0")
        }

        let release = try JSONDecoder().decode(APIRelease.self, from: data)
        let version = normalizeVersion(release.tagName)
        let asset = release.assets.first(where: {
            guard $0.name.hasSuffix(".pkg") else { return false }
            let name = $0.name.lowercased()
            return name.contains("clipbar") || name.contains("clipboard-manager")
        }) ?? release.assets.first(where: { $0.name.hasSuffix(".pkg") })

        let pkgName = asset?.name ?? "ClipBar-\(version).pkg"
        var directs: [URL] = []
        if let asset, let url = URL(string: asset.browserDownloadURL) {
            directs.append(url)
        }
        directs.append(contentsOf: pkgCandidateURLs(version: version, tag: release.tagName))

        return ReleaseInfo(
            tagName: release.tagName,
            htmlURL: release.htmlURL,
            body: release.body,
            pkgName: pkgName,
            expectedSize: asset?.size,
            downloadURLs: prioritizedDownloadURLs(directs)
        )
    }

    private static func pkgCandidateURLs(version: String, tag: String) -> [URL] {
        let names = [
            "ClipBar-\(version).pkg",
            "ClipBar-\(tag).pkg",
            "Clipboard-Manager-\(version).pkg",
            "Clipboard-Manager-\(tag).pkg",
        ]
        return names.compactMap {
            URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\($0)")
        }
    }

    /// 镜像优先，直连垫后；去重保序。
    private static func prioritizedDownloadURLs(_ directs: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        func append(_ url: URL) {
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return }
            result.append(url)
        }
        for direct in directs {
            for mirror in downloadMirrors {
                if let mirrored = URL(string: mirror + direct.absoluteString) {
                    append(mirrored)
                }
            }
        }
        for direct in directs {
            append(direct)
        }
        return result
    }

    private static func extractTag(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if let idx = parts.firstIndex(of: "tag"), idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    private static func downloadWithProgress(
        urls: [URL],
        named name: String,
        expectedSize: Int64?
    ) async throws -> URL {
        var lastError: Error = UpdateError.downloadFailed
        for (index, candidate) in urls.enumerated() {
            UpdateProgressModel.shared.statusText =
                "正在下载…（线路 \(index + 1)/\(urls.count)）"
            DebugLog.write("下载尝试 \(index + 1)/\(urls.count): \(candidate.absoluteString)")
            do {
                let file = try await DownloadSession.shared.download(from: candidate, named: name) { fraction in
                    Task { @MainActor in
                        UpdateProgressModel.shared.fractionCompleted = fraction
                        let pct = Int(fraction * 100)
                        UpdateProgressModel.shared.statusText = "正在下载… \(pct)%"
                    }
                }
                if isValidPKG(at: file, expectedSize: expectedSize) {
                    return file
                }
                DebugLog.write("下载文件校验失败：\(file.path) size=\(fileSize(file))")
                try? FileManager.default.removeItem(at: file)
                lastError = UpdateError.corruptPackage
            } catch {
                lastError = error
                DebugLog.write("下载失败：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    private static func isValidPKG(at url: URL, expectedSize: Int64?) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size > 1024 else { return false }
        if let expectedSize, expectedSize > 0, size != expectedSize {
            return false
        }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 4),
              magic == Data("xar!".utf8) else { return false }
        return true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
    }

    // MARK: - UI

    private static func confirmUpdate(version: String, notes: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        let body = (notes?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        alert.informativeText = body
            ?? "当前版本 \(currentVersion)。将自动下载安装包并打开安装器，随后 ClipBar 会退出以便完成更新。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentAlert(
        title: String,
        message: String,
        style: NSAlert.Style,
        openURL: URL? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        if openURL != nil {
            alert.addButton(withTitle: "打开 Releases")
            alert.addButton(withTitle: "好")
        } else {
            alert.addButton(withTitle: "好")
        }
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        if openURL != nil, result == .alertFirstButtonReturn, let openURL {
            NSWorkspace.shared.open(openURL)
        }
    }

    // MARK: - Version

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s.removeFirst()
        }
        return s
    }

    static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    private enum UpdateError: LocalizedError {
        case http(Int, rateLimited: Bool)
        case invalidResponse
        case parseFailed
        case downloadFailed
        case corruptPackage

        var errorDescription: String? {
            switch self {
            case .http(let code, let rateLimited):
                if rateLimited || code == 403 {
                    return "GitHub 请求受限（HTTP \(code)）。请稍后再试。"
                }
                if code == 404 {
                    return "未找到 Release（HTTP 404）。"
                }
                return "GitHub 返回 HTTP \(code)"
            case .invalidResponse:
                return "无法解析 GitHub 响应，请检查网络后重试。"
            case .parseFailed:
                return "无法识别最新版本号，请稍后重试。"
            case .downloadFailed:
                return "安装包下载失败（网络不稳定）。请重试。"
            case .corruptPackage:
                return "下载的安装包不完整或已损坏，请重试。"
            }
        }
    }
}

// MARK: - 带进度的下载

private final class DownloadSession: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadSession()

    private let lock = NSLock()
    private var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var destinationName: String = "update.pkg"
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func download(
        from url: URL,
        named name: String,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.progressHandler = onProgress
            self.destinationName = name
            self.lock.unlock()
            var request = URLRequest(url: url)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            request.setValue("ClipBar/\(version)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 300
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(min(max(fraction, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "UpdateChecker",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "下载失败 HTTP \(http.statusCode)"]
                )
            }
            let dir = AppPaths.updatesDirectory()
            let dest = dir.appendingPathComponent(destinationName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            progressHandler?(1)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        progressHandler = nil
        lock.unlock()
        guard let cont else { return }
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}
