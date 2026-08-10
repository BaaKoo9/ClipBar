import AppKit
import ClipboardManagerCore
import Foundation

/// 检查 GitHub Release 并引导安装最新 pkg。
/// 优先走网页重定向（不消耗 api.github.com 匿名配额），API 仅作后备。
@MainActor
enum UpdateChecker {
    private static let owner = "BaaKoo9"
    private static let repo = "ClipBar"
    private static let latestPageURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    private static let userAgent = "ClipBar/\(currentVersion) (+https://github.com/\(owner)/\(repo))"

    private struct ReleaseInfo {
        let tagName: String
        let htmlURL: String
        let body: String?
        let pkgURL: URL?
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
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 从菜单触发：检查 → 提示 → 下载 pkg → 打开安装器。
    /// `interactive == false` 时静默写入设置，不弹窗。
    static func checkForUpdates(interactive: Bool = true) {
        DebugLog.write("检查更新：当前版本 \(currentVersion) interactive=\(interactive)")
        if interactive {
            ToastWindowController.shared.show(
                title: "正在检查更新…",
                message: "连接 GitHub Releases",
                systemImage: "arrow.triangle.2.circlepath"
            )
        }

        Task {
            do {
                let release = try await fetchLatestRelease()
                let remote = normalizeVersion(release.tagName)
                let local = normalizeVersion(currentVersion)
                AppSettings.shared.lastUpdateCheckAt = Date().timeIntervalSince1970
                DebugLog.write("检查更新：远程 \(remote) 本地 \(local)")

                if compareVersion(remote, local) <= 0 {
                    AppSettings.shared.availableUpdateVersion = nil
                    NotificationCenter.default.post(name: .clipboardUpdateAvailable, object: nil)
                    if interactive {
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

                guard let downloadURL = release.pkgURL else {
                    presentAlert(
                        title: "发现新版本 \(remote)",
                        message: "未找到可下载的安装包，请前往 GitHub Releases 手动下载。",
                        style: .warning,
                        openURL: URL(string: release.htmlURL)
                    )
                    return
                }

                let go = confirmUpdate(version: remote, notes: release.body)
                guard go else {
                    AppSettings.shared.dismissedUpdateVersion = remote
                    NotificationCenter.default.post(name: .clipboardUpdateAvailable, object: nil)
                    return
                }

                ToastWindowController.shared.show(
                    title: "正在下载 \(remote)…",
                    message: downloadURL.lastPathComponent,
                    systemImage: "arrow.down.circle"
                )
                let pkgURL = try await download(from: downloadURL, named: downloadURL.lastPathComponent)
                DebugLog.write("检查更新：已下载 \(pkgURL.path)")

                NSWorkspace.shared.open(pkgURL)
                ToastWindowController.shared.show(
                    title: "已打开安装器",
                    message: "按提示完成安装即可升级到 \(remote)",
                    systemImage: "checkmark.circle"
                )
            } catch {
                DebugLog.write("检查更新失败：\(error.localizedDescription)")
                if interactive {
                    presentAlert(
                        title: "检查更新失败",
                        message: error.localizedDescription,
                        style: .warning,
                        openURL: latestPageURL
                    )
                }
            }
        }
    }

    /// 启动后调度：约 30s 首次静默检查，之后每 24h。
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

    private static func fetchLatestRelease() async throws -> ReleaseInfo {
        if let web = try? await fetchViaRedirect() {
            return web
        }
        return try await fetchViaAPI()
    }

    /// 不走 api.github.com，避免匿名 60 次/小时配额被打满后返回 403。
    private static func fetchViaRedirect() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestPageURL)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: config)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        // HEAD + 跟随重定向后，最终 URL 形如 …/releases/tag/v1.0.4
        var tagURL = http.url
        if tagURL == nil || extractTag(from: tagURL!) == nil,
           let location = http.value(forHTTPHeaderField: "Location"),
           let loc = URL(string: location) {
            tagURL = loc
        }
        guard let url = tagURL, let tag = extractTag(from: url) else {
            // 部分网络对 HEAD 不友好，再试一次轻量 GET
            return try await fetchViaRedirectGET()
        }

        let version = normalizeVersion(tag)
        return ReleaseInfo(
            tagName: tag,
            htmlURL: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)",
            body: nil,
            pkgURL: pkgDownloadURL(version: version, tag: tag)
        )
    }

    private static func fetchViaRedirectGET() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestPageURL)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let url = http.url,
              let tag = extractTag(from: url) else {
            throw UpdateError.parseFailed
        }
        let version = normalizeVersion(tag)
        return ReleaseInfo(
            tagName: tag,
            htmlURL: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)",
            body: nil,
            pkgURL: pkgDownloadURL(version: version, tag: tag)
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

        let pkgURL: URL?
        if let asset, let url = URL(string: asset.browserDownloadURL) {
            pkgURL = url
        } else {
            pkgURL = pkgDownloadURL(version: version, tag: release.tagName)
        }

        return ReleaseInfo(
            tagName: release.tagName,
            htmlURL: release.htmlURL,
            body: release.body,
            pkgURL: pkgURL
        )
    }

    private static func pkgDownloadURL(version: String, tag: String) -> URL? {
        // 优先新命名；旧 Release 资产名仍兼容
        let candidates = [
            "ClipBar-\(version).pkg",
            "ClipBar-\(tag).pkg",
            "Clipboard-Manager-\(version).pkg",
            "Clipboard-Manager-\(tag).pkg",
        ]
        guard let name = candidates.first else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(name)")
    }

    private static func extractTag(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        // .../releases/tag/v1.0.4
        if let idx = parts.firstIndex(of: "tag"), idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    private static func download(from url: URL, named name: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode, rateLimited: false)
        }

        let dir = AppPaths.updatesDirectory()
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - UI

    private static func confirmUpdate(version: String, notes: String?) -> Bool {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        let body = (notes?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        alert.informativeText = body ?? "当前版本 \(currentVersion)。下载安装包后将打开系统安装器完成更新。"
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

    /// 比较语义化版本，lhs > rhs 返回正数。
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

        var errorDescription: String? {
            switch self {
            case .http(let code, let rateLimited):
                if rateLimited || code == 403 {
                    return "GitHub 请求受限（HTTP \(code)）。请稍后再试，或打开 Releases 页面手动下载。"
                }
                if code == 404 {
                    return "未找到 Release（HTTP 404）。请确认仓库已发布安装包。"
                }
                return "GitHub 返回 HTTP \(code)"
            case .invalidResponse:
                return "无法解析 GitHub 响应，请检查网络后重试。"
            case .parseFailed:
                return "无法识别最新版本号，请打开 Releases 页面查看。"
            }
        }
    }
}
