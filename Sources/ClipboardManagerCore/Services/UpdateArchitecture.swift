import Darwin
import Foundation

/// 发布制品按硬件架构选择；Rosetta 下运行的 Intel 版也应迁移到原生 ARM 版。
public enum UpdateArchitecture: String, CaseIterable {
    case arm64
    case x86_64

    public static var current: UpdateArchitecture {
        var supported: Int32 = 0
        var size = MemoryLayout.size(ofValue: supported)
        if sysctlbyname("hw.optional.arm64", &supported, &size, nil, 0) == 0, supported == 1 {
            return .arm64
        }
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }

    /// 本项目只发布单架构 Mach-O；安装前同时检查主程序和更新助手的真实头部。
    public func matchesExecutable(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32), data.count == 32 else { return false }
        let bytes = Array(data)
        guard Array(bytes.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] else { return false }
        let cpu = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        let expected: UInt32 = self == .arm64 ? 0x0100000c : 0x01000007
        // MH_EXECUTE，不能拿同架构动态库冒充可执行文件。
        return cpu == expected && Array(bytes[12..<16]) == [2, 0, 0, 0]
    }
}
