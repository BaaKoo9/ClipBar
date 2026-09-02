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

    /// 优先选择带同名 SHA-256 文件的 DMG；旧版 Release 没有 DMG 校验时安全回退到 pkg。
    public static func preferredArtifactName(from assetNames: [String], version: String) -> String? {
        let names = Set(assetNames)
        let normalizedVersion = normalizeVersion(version)
        let preferredNames = [
            "ClipBar-\(normalizedVersion).dmg",
            "ClipBar-\(normalizedVersion).pkg",
        ]

        if let exact = preferredNames.first(where: { names.contains($0) && names.contains("\($0).sha256") }) {
            return exact
        }
        return assetNames.first(where: { name in
            let lowercased = name.lowercased()
            return (lowercased.hasSuffix(".dmg") || lowercased.hasSuffix(".pkg"))
                && names.contains("\(name).sha256")
        })
    }
}
