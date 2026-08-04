import AppKit
import Foundation

/// 全局快捷键服务：基于 NSEvent 全局键盘监听。
/// 需要「输入监控」权限（macOS 系统设置 → 隐私与安全性 → 输入监控）。
public final class HotKeyService {
    public static let shared = HotKeyService()

    private struct Registration {
        let keyCode: Int
        let modifiers: UInt
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var monitor: Any?
    private let lock = NSLock()

    private init() {}

    /// 是否已获得输入监控权限。
    public static var isListeningAvailable: Bool {
        CGPreflightListenEventAccess()
    }

    /// 主动请求输入监控权限（弹出系统授权框）。
    @discardableResult
    public static func requestListeningAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    /// 注册全局快捷键；同 tag 覆盖旧注册。
    @discardableResult
    public func register(
        tag: UInt32,
        keyCode: Int,
        modifiers: UInt,
        handler: @escaping () -> Void
    ) -> Bool {
        lock.lock()
        registrations[tag] = Registration(keyCode: keyCode, modifiers: modifiers, handler: handler)
        lock.unlock()
        rebuildMonitor()
        return true
    }

    public func unregister(tag: UInt32) {
        lock.lock()
        registrations.removeValue(forKey: tag)
        lock.unlock()
        rebuildMonitor()
    }

    public static func unregisterAll() {
        shared.unregisterAll()
    }

    private func unregisterAll() {
        lock.lock()
        registrations.removeAll()
        lock.unlock()
        rebuildMonitor()
    }

    /// 授权变化（如用户从系统设置返回）后重新挂载监听。
    public func rebuildMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        lock.lock()
        let hasRegistrations = !registrations.isEmpty
        lock.unlock()
        guard hasRegistrations, Self.isListeningAvailable else { return }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let carbonFlags = Self.carbonModifiers(from: flags)
        let keyCode = Int(event.keyCode)

        lock.lock()
        let matches = registrations.values.filter {
            $0.keyCode == keyCode && $0.modifiers == carbonFlags
        }
        lock.unlock()

        for registration in matches {
            registration.handler()
        }
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt {
        var value: UInt = 0
        if flags.contains(.control) { value |= 4096 }
        if flags.contains(.option) { value |= 2048 }
        if flags.contains(.shift) { value |= 512 }
        if flags.contains(.command) { value |= 256 }
        return value
    }
}
