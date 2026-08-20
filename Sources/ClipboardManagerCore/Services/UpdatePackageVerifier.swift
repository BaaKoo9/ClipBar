import CryptoKit
import Foundation

/// 自动更新包的纯函数校验工具，独立于网络与 UI，便于回归测试。
public enum UpdatePackageVerifier {
    public static let maximumChecksumFileSize = 4_096

    /// 接受 `sha256sum` / `shasum -a 256` 常见格式，返回标准小写摘要。
    public static func parseSHA256(from data: Data) -> String? {
        guard data.count <= maximumChecksumFileSize,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .lazy
            .map(String.init)
            .first(where: isSHA256Digest)?
            .lowercased()
    }

    /// 流式读取文件，避免未来安装包增大后一次性占用同等内存。
    public static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return (48...57).contains(code)
                || (65...70).contains(code)
                || (97...102).contains(code)
        }
    }
}
