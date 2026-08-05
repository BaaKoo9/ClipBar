import AppKit
import Carbon
import CoreGraphics
import Foundation

// MARK: - CGEventTap 回调

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        HotKeyService.shared.handleTapDisabled(reason: type == .tapDisabledByTimeout ? "超时" : "用户输入")
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let carbonFlags = HotKeyService.carbonModifiers(from: event.flags)
    if let tag = HotKeyService.shared.matchedTag(keyCode: keyCode, modifiers: carbonFlags) {
        HotKeyService.shared.fire(tag: tag, source: "tap")
        return nil
    }
    // 诊断：按键码命中任一注册，但修饰键不符 → 便于发现「按了没反应」是匹配问题
    HotKeyService.shared.logNearMissIfNeeded(keyCode: keyCode, modifiers: carbonFlags, source: "tap")
    return Unmanaged.passUnretained(event)
}

// MARK: - Carbon 热键回调

private func carbonHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    HotKeyService.shared.fire(tag: hotKeyID.id, source: "carbon")
    return noErr
}

// MARK: - 服务

/// 全局快捷键：Carbon RegisterEventHotKey（系统级，最稳）为主，
/// CGEventTap（可消费事件防透传）+ NSEvent 全局监听为辅。
///
/// 历史教训：把 tap 的 RunLoopSource 挂到后台线程，在部分启动时机收不到事件；
/// 现改回主线程 runloop。Carbon 通道不依赖事件流顺序，重启后应立即生效。
public final class HotKeyService {
    public static let shared = HotKeyService()

    public struct Status {
        public let accessibility: Bool
        public let listening: Bool
        public let tapActive: Bool
        public let carbonCount: Int

        public var isWorking: Bool { carbonCount > 0 || tapActive || listening }

        public var description: String {
            if carbonCount > 0, tapActive { return "正常（Carbon+Tap）" }
            if carbonCount > 0 { return "正常（Carbon）" }
            if tapActive { return "降级（仅 Tap）" }
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
    private var carbonHotKeys: [UInt32: EventHotKeyRef] = [:]
    private var carbonHandlerRef: EventHandlerRef?
    private var monitor: Any?
    private var watchdogTimer: Timer?
    private var lastListeningAvailable = false
    private var lastAccessibilityAvailable = false
    private let lock = NSLock()

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var retryAttempt = 0
    private var lastHealthLogTime: CFAbsoluteTime = 0

    private var lastFireTag: UInt32 = 0
    private var lastFireTime: CFAbsoluteTime = 0
    private var lastNearMissTime: CFAbsoluteTime = 0

    private static let carbonSignature: OSType = 0x434C4950 // 'CLIP'

    private init() {
        lastAccessibilityAvailable = Self.isAccessibilityAvailable
        lastListeningAvailable = Self.isListeningAvailable
        installCarbonHandler()
        installEventTap()
        startWatchdog()
    }

    public static var isAccessibilityAvailable: Bool {
        AXIsProcessTrusted()
    }

    public static func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public static var isListeningAvailable: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    public static func requestListeningAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    public var status: Status {
        lock.lock()
        let tapActive = eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let carbonCount = carbonHotKeys.count
        lock.unlock()
        return Status(
            accessibility: Self.isAccessibilityAvailable,
            listening: Self.isListeningAvailable,
            tapActive: tapActive,
            carbonCount: carbonCount
        )
    }

    public func reinitialize() {
        DebugLog.write("手动重新初始化快捷键通道")
        lock.lock()
        retryAttempt = 0
        lock.unlock()
        teardownEventTap()
        unregisterAllCarbonHotKeys()
        // 激活后重装：LSUIElement 冷启动时首次 Install/Register 可能成功但不派发
        if carbonHandlerRef != nil {
            RemoveEventHandler(carbonHandlerRef)
            carbonHandlerRef = nil
        }
        installCarbonHandler()
        installEventTap()
        reregisterAllCarbonHotKeys()
        rebuildMonitor()
        logChannelSnapshot(reason: "reinitialize")
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

        let carbonOK = registerCarbonHotKey(tag: tag, keyCode: keyCode, modifiers: modifiers)
        rebuildMonitor()
        ensureTapHealthy()
        let hasTap = self.eventTap != nil
        DebugLog.write(
            "注册 tag=\(tag) key=\(keyCode) mods=\(modifiers) carbon=\(carbonOK) " +
            "tap=\(hasTap) listening=\(Self.isListeningAvailable)"
        )
        return carbonOK || hasTap || Self.isListeningAvailable
    }

    public func unregister(tag: UInt32) {
        lock.lock()
        registrations.removeValue(forKey: tag)
        lock.unlock()
        unregisterCarbonHotKey(tag: tag)
    }

    public static func unregisterAll() {
        shared.unregisterAll()
    }

    private func unregisterAll() {
        lock.lock()
        registrations.removeAll()
        lock.unlock()
        unregisterAllCarbonHotKeys()
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

    func logNearMissIfNeeded(keyCode: Int, modifiers: UInt, source: String) {
        lock.lock()
        let hit = registrations.first { $0.value.keyCode == keyCode }
        lock.unlock()
        guard let (tag, reg) = hit, reg.modifiers != modifiers else { return }

        let now = CFAbsoluteTimeGetCurrent()
        // 同一近失配 1s 内只记一次，避免按住时刷屏
        lock.lock()
        if now - lastNearMissTime < 1.0 {
            lock.unlock()
            return
        }
        lastNearMissTime = now
        lock.unlock()

        DebugLog.write(
            "热键近失配 来源=\(source) tag=\(tag) key=\(keyCode) " +
            "实际mods=\(modifiers) 期望mods=\(reg.modifiers)"
        )
    }

    // MARK: - 触发

    func fire(tag: UInt32, source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if tag == lastFireTag, now - lastFireTime < 0.25 {
            lock.unlock()
            DebugLog.write("热键去重 tag=\(tag) 来源=\(source)")
            return
        }
        lastFireTag = tag
        lastFireTime = now
        let handler = registrations[tag]?.handler
        lock.unlock()

        guard let handler else {
            DebugLog.write("热键命中但无 handler tag=\(tag) 来源=\(source)")
            return
        }
        DebugLog.write("热键命中 tag=\(tag) 来源=\(source) 启动后\(LaunchClock.elapsedMilliseconds)ms")
        if Thread.isMainThread {
            handler()
        } else {
            DispatchQueue.main.async(execute: handler)
        }
    }

    // MARK: - Carbon

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            nil,
            &carbonHandlerRef
        )
        DebugLog.write("Carbon 事件处理器安装 status=\(status)")
    }

    @discardableResult
    private func registerCarbonHotKey(tag: UInt32, keyCode: Int, modifiers: UInt) -> Bool {
        unregisterCarbonHotKey(tag: tag)

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.carbonSignature, id: tag)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            DebugLog.write("Carbon 注册失败 tag=\(tag) status=\(status)")
            return false
        }
        lock.lock()
        carbonHotKeys[tag] = hotKeyRef
        lock.unlock()
        return true
    }

    private func unregisterCarbonHotKey(tag: UInt32) {
        lock.lock()
        let ref = carbonHotKeys.removeValue(forKey: tag)
        lock.unlock()
        if let ref {
            UnregisterEventHotKey(ref)
        }
    }

    private func unregisterAllCarbonHotKeys() {
        lock.lock()
        let refs = Array(carbonHotKeys.values)
        carbonHotKeys.removeAll()
        lock.unlock()
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
    }

    private func reregisterAllCarbonHotKeys() {
        lock.lock()
        let snapshot = registrations
        lock.unlock()
        for (tag, reg) in snapshot {
            _ = registerCarbonHotKey(tag: tag, keyCode: reg.keyCode, modifiers: reg.modifiers)
        }
    }

    // MARK: - NSEvent 监听

    public func rebuildMonitor() {
        let install = { [weak self] in
            guard let self else { return }
            if let monitor = self.monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            self.lock.lock()
            let hasRegistrations = !self.registrations.isEmpty
            self.lock.unlock()
            guard hasRegistrations else { return }
            guard Self.isListeningAvailable else {
                DebugLog.write("NSEvent 监听未安装：无输入监控权限")
                return
            }
            self.monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.monitorHandle(event)
            }
            DebugLog.write("NSEvent 全局监听已安装")
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
        let keyCode = Int(event.keyCode)
        if let tag = matchedTag(keyCode: keyCode, modifiers: carbonFlags) {
            fire(tag: tag, source: "monitor")
        } else {
            logNearMissIfNeeded(keyCode: keyCode, modifiers: carbonFlags, source: "monitor")
        }
    }

    // MARK: - CGEventTap（主线程 runloop）

    private func teardownEventTap() {
        lock.lock()
        let tap = eventTap
        let source = eventTapSource
        eventTap = nil
        eventTapSource = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func installEventTap() {
        guard Self.isAccessibilityAvailable else {
            DebugLog.write("CGEventTap 跳过安装：无辅助功能权限")
            return
        }

        // 先拆掉旧的，避免重复挂到主 runloop
        teardownEventTap()

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

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // 挂主线程 runloop：跨线程挂源在部分启动时机收不到事件（本次回归的主因之一）
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        eventTap = tap
        eventTapSource = source
        retryAttempt = 0
        lock.unlock()

        DebugLog.write("CGEventTap 已启用（主线程 runloop）")
    }

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
            if !CGEvent.tapIsEnabled(tap: tap) {
                DebugLog.write("CGEventTap 已失效，重建")
                teardownEventTap()
                installEventTap()
            }
        }
    }

    private func logChannelSnapshot(reason: String) {
        let s = status
        DebugLog.write(
            "通道快照[\(reason)] carbon=\(s.carbonCount) tap=\(s.tapActive) " +
            "listening=\(s.listening) ax=\(s.accessibility) 状态=\(s.description)"
        )
    }

    // MARK: - 看护

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
                installEventTap()
                if !Self.isListeningAvailable {
                    Self.requestListeningAccess()
                }
            } else {
                teardownEventTap()
            }
        }

        ensureTapHealthy()

        // Carbon 热键若被系统清掉（极少见），看护期间补注册
        lock.lock()
        let regCount = registrations.count
        let carbonCount = carbonHotKeys.count
        lock.unlock()
        if regCount > 0, carbonCount < regCount {
            DebugLog.write("Carbon 热键缺失 \(carbonCount)/\(regCount)，补注册")
            reregisterAllCarbonHotKeys()
        }

        let listening = Self.isListeningAvailable
        if listening != lastListeningAvailable {
            lastListeningAvailable = listening
            DebugLog.write("输入监控权限变化：\(listening)")
            rebuildMonitor()
        }

        // 启动后前 30 秒每 6 秒打一次通道快照，方便对照「按了没反应」时段
        let elapsed = LaunchClock.elapsedMilliseconds
        let now = CFAbsoluteTimeGetCurrent()
        if elapsed < 30_000, now - lastHealthLogTime >= 6 {
            lastHealthLogTime = now
            logChannelSnapshot(reason: "watchdog+\(elapsed)ms")
        }
    }

    // MARK: - 修饰键

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
