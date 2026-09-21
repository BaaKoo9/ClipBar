import Foundation

/// 更新提示与 Release 附件选择的纯策略，避免 UI 层持久化出过期状态。
public enum UpdatePolicy {
    public static func normalizeVersion(_ raw: String) -> String {
        var version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.lowercased().hasPrefix("v") {
            version.removeFirst()
        }
        return version
    }

    public static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = normalizeVersion(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let right = normalizeVersion(rhs).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart {
                return leftPart > rightPart ? 1 : -1
            }
        }
        return 0
    }

    public static func shouldSurfaceUpdate(
        availableVersion: String?,
        dismissedVersion: String?,
        currentVersion: String
    ) -> Bool {
        guard let availableVersion,
              compareVersion(availableVersion, currentVersion) > 0 else {
            return false
        }
        return normalizeVersion(availableVersion) != dismissedVersion.map(normalizeVersion)
    }

    /// 仅选择本机架构且带校验的确切版本；旧的无架构名仅属于 Apple Silicon。
    public static func preferredArtifactName(
        from assetNames: [String], version: String, architecture: UpdateArchitecture = .current
    ) -> String? {
        let names = Set(assetNames)
        let normalizedVersion = normalizeVersion(version)
        var preferredNames = [
            "ClipBar-\(normalizedVersion)-\(architecture.rawValue).dmg",
            "ClipBar-\(normalizedVersion)-\(architecture.rawValue).pkg",
        ]
        if architecture == .arm64 {
            preferredNames += ["ClipBar-\(normalizedVersion).dmg", "ClipBar-\(normalizedVersion).pkg"]
        }
        return preferredNames.first { names.contains($0) && names.contains("\($0).sha256") }
    }
}
