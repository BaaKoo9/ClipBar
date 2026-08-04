import AppKit
import CoreGraphics
import Foundation

// MARK: - CGEventTap 文件级状态

/// tap 运行在独立线程的 runloop 上：主线程卡顿不会让系统把 tap 判定为超时而禁用，
/// 同时按键回调不必排队等待主线程，是热键响应速度的关键。
private final class EventTapThread: Thread {
    private(set) var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        ready.signal()
        while !isCancelled {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }
    }

    func waitUntilReady() {
        _ = ready.wait(timeout: .now() + 2)
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    // 系统在 tap 回调超时或用户输入抢占时会禁用 tap，必须就地恢复，否则热键永久失效。
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        HotKeyService.shared.handleTapDisabled(reason: type == .tapDisabledByTimeout ? "超时" : "用户输入")
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }
    // 过滤按住不放的自动重复
    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let carbonFlags = HotKeyService.carbonModifiers(from: event.flags)
    if let tag = HotKeyService.shared.matchedTag(keyCode: keyCode, modifiers: carbonFlags) {
        HotKeyService.shared.fire(tag: tag, source: "tap")
        return nil // 消费事件，避免透传给前台 App
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - 服务

/// 全局快捷键服务：CGEventTap（辅助功能权限）为主，NSEvent 全局监听（输入监控权限）为辅。
///
/// 可靠性要点：`AXIsProcessTrusted()` 返回 true 时系统 TCC 缓存可能尚未刷新，
/// `CGEvent.tapCreate` 仍会失败。因此创建失败必须持续重试，并由看护定时器兜底自愈。
public final class HotKeyService {
    public static let shared = HotKeyService()

    /// 快捷键通道状态，供 UI 展示。
    public struct Status {
        public let accessibility: Bool
        public let listening: Bool
        public let tapActive: Bool

        /// 主通道（可消费事件）或辅通道（仅监听）任一可用即视为快捷键生效。
        public var isWorking: Bool { tapActive || listening }

        public var description: String {
            if tapActive { return "正常（主通道）" }
            if listening { return "降级（仅辅助通道）" }
            if !accessibility { return "未授权辅助功能" }
            return "异常，请重新初始化"
        }
    }

    private struct Registration {
        let keyCode: Int
        let modifiers: UInt
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var monitor: Any?
    private var watchdogTimer: Timer?
    private var lastListeningAvailable = false
    private var lastAccessibilityAvailable = false
    private let lock = NSLock()

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var tapThread: EventTapThread?
    private var retryAttempt = 0

    private var lastFireTag: UInt32 = 0
    private var lastFireTime: CFAbsoluteTime = 0

    private init() {
        lastAccessibilityAvailable = Self.isAccessibilityAvailable
        lastListeningAvailable = Self.isListeningAvailable
        installEventTap()
        startWatchdog()
    }

    /// 是否拥有辅助功能权限（CGEventTap 需要）。
    public static var isAccessibilityAvailable: Bool {
        AXIsProcessTrusted()
    }

    /// 主动请求辅助功能权限（弹出系统授权框）。
    public static func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 是否拥有输入监控权限（NSEvent 监听需要）。
    public static var isListeningAvailable: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func requestListeningAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    /// 当前快捷键通道状态。
    public var status: Status {
        lock.lock()
        let tapActive = eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        lock.unlock()
        return Status(
            accessibility: Self.isAccessibilityAvailable,
            listening: Self.isListeningAvailable,
            tapActive: tapActive
        )
    }

    /// 手动重建全部监听通道（菜单「重新初始化快捷键」）。
    public func reinitialize() {
        DebugLog.write("手动重新初始化快捷键通道")
        lock.lock()
        retryAttempt = 0
        lock.unlock()
        teardownEventTap()
        installEventTap()
        rebuildMonitor()
    }

    // MARK: - 注册

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
        ensureTapHealthy()
        return true
    }

    public func unregister(tag: UInt32) {
        lock.lock()
        registrations.removeValue(forKey: tag)
        lock.unlock()
    }

    public static func unregisterAll() {
        shared.unregisterAll()
    }

    private func unregisterAll() {
        lock.lock()
        registrations.removeAll()
        lock.unlock()
    }

    // MARK: - 匹配

    func matchedTag(keyCode: Int, modifiers: UInt) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        for (tag, registration) in registrations
        where registration.keyCode == keyCode && registration.modifiers == modifiers {
            return tag
        }
        return nil
    }

    // MARK: - 触发（线程安全，统一回主线程）

    func fire(tag: UInt32, source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if tag == lastFireTag, now - lastFireTime < 0.25 {
            lock.unlock()
            return
        }
        lastFireTag = tag
        lastFireTime = now
        let handler = registrations[tag]?.handler
        lock.unlock()

        guard let handler else { return }
        DebugLog.write("热键命中 tag=\(tag) 来源=\(source) 启动后\(LaunchClock.elapsedMilliseconds)ms")
        DispatchQueue.main.async(execute: handler)
    }

    // MARK: - NSEvent 监听（输入监控权限，辅助通道）

    public func rebuildMonitor() {
        let install = {
            if let monitor = self.monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            self.lock.lock()
            let hasRegistrations = !self.registrations.isEmpty
            self.lock.unlock()
            guard hasRegistrations, Self.isListeningAvailable else { return }
            self.monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.monitorHandle(event)
            }
        }
        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.async(execute: install)
        }
    }

    private func monitorHandle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let carbonFlags = Self.carbonModifiers(from: flags)
        if let tag = matchedTag(keyCode: Int(event.keyCode), modifiers: carbonFlags) {
            fire(tag: tag, source: "monitor")
        }
    }

    // MARK: - CGEventTap

    private func teardownEventTap() {
        lock.lock()
        let tap = eventTap
        let source = eventTapSource
        let thread = tapThread
        eventTap = nil
        eventTapSource = nil
        tapThread = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source, let runLoop = thread?.runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        thread?.cancel()
    }

    private func installEventTap() {
        guard Self.isAccessibilityAvailable else {
            DebugLog.write("CGEventTap 跳过安装：无辅助功能权限")
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: nil
        ) else {
            scheduleTapRetry()
            return
        }

        let thread = EventTapThread()
        thread.name = "com.huxiaolong.clipboard.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        thread.waitUntilReady()

        guard let runLoop = thread.runLoop else {
            thread.cancel()
            scheduleTapRetry()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        eventTap = tap
        eventTapSource = source
        tapThread = thread
        retryAttempt = 0
        lock.unlock()

        DebugLog.write("CGEventTap 已启用（独立线程）")
    }

    /// `AXIsProcessTrusted()` 为 true 时 tapCreate 仍可能失败（TCC 缓存滞后），退避重试直到成功。
    private func scheduleTapRetry() {
        lock.lock()
        retryAttempt += 1
        let attempt = retryAttempt
        lock.unlock()

        let delay = min(0.4 * Double(attempt), 3.0)
        DebugLog.write("CGEventTap 创建失败，第 \(attempt) 次重试将在 \(String(format: "%.1f", delay))s 后")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ensureTapHealthy()
        }
    }

    func handleTapDisabled(reason: String) {
        DebugLog.write("CGEventTap 被系统禁用（\(reason)），立即恢复")
        lock.lock()
        let tap = eventTap
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// 检查主通道是否健康，不健康就地修复。
    private func ensureTapHealthy() {
        guard Self.isAccessibilityAvailable else { return }
        lock.lock()
        let tap = eventTap
        lock.unlock()

        guard let tap else {
            installEventTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            // 重新启用无效说明 tap 已失效，整体重建。
            if !CGEvent.tapIsEnabled(tap: tap) {
                DebugLog.write("CGEventTap 已失效，重建")
                teardownEventTap()
                installEventTap()
            }
        }
    }

    // MARK: - 看护定时器：权限变化 + 通道健康

    private func startWatchdog() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func watchdogTick() {
        let accessibility = Self.isAccessibilityAvailable
        if accessibility != lastAccessibilityAvailable {
            lastAccessibilityAvailable = accessibility
            DebugLog.write("辅助功能权限变化：\(accessibility)")
            if accessibility {
                lock.lock()
                retryAttempt = 0
                lock.unlock()
                if !Self.isListeningAvailable {
                    Self.requestListeningAccess()
                }
            } else {
                teardownEventTap()
            }
        }

        ensureTapHealthy()

        let listening = Self.isListeningAvailable
        guard listening != lastListeningAvailable else { return }
        lastListeningAvailable = listening
        DebugLog.write("输入监控权限变化：\(listening)")
        rebuildMonitor()
    }

    // MARK: - 修饰键转换

    static func carbonModifiers(from flags: CGEventFlags) -> UInt {
        var value: UInt = 0
        if flags.contains(.maskControl) { value |= 4096 }
        if flags.contains(.maskAlternate) { value |= 2048 }
        if flags.contains(.maskShift) { value |= 512 }
        if flags.contains(.maskCommand) { value |= 256 }
        return value
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
