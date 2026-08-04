import Carbon
import Foundation

// 文件级状态：Carbon 的 C 回调不能捕获类型上下文，因此用全局变量承载。
private var hotKeyHandlers: [UInt32: (() -> Void)] = [:]
private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
private var eventHandlerRef: EventHandlerRef?

// 四字符常量（避免 Carbon 宏在 Swift 中的兼容问题）
private let hotKeyEventClass: OSType = 0x6B657962 // 'keyb'
private let hotKeyPressedKind: UInt32 = 1
private let hotKeyTypeID: OSType = 0x686B6964 // 'hkid'
private let hotKeyParamName: UInt32 = 0x6469726F // 'diro'
private let hotKeySignature: OSType = 0x434D484B // 'CMHK'

private func fireHotKeyHandler(id: UInt32) {
    DispatchQueue.main.async {
        hotKeyHandlers[id]?()
    }
}

/// 全局快捷键服务（Carbon RegisterEventHotKey，无需辅助功能权限）。
/// 支持注册多个热键，用 tag 区分。
public final class HotKeyService {
    public static let shared = HotKeyService()

    private init() {
        installEventHandler()
    }

    deinit {
        Self.unregisterAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// 注册全局快捷键；同 tag 会先注销旧的。返回是否注册成功。
    @discardableResult
    public func register(
        tag: UInt32,
        keyCode: Int,
        modifiers: UInt,
        handler: @escaping () -> Void
    ) -> Bool {
        unregister(tag: tag)

        var hotKeyID = EventHotKeyID(signature: hotKeySignature, id: tag)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            print("RegisterEventHotKey 失败(tag=\(tag)): \(status)")
            return false
        }
        hotKeyRefs[tag] = ref
        hotKeyHandlers[tag] = handler
        return true
    }

    public func unregister(tag: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: tag) {
            UnregisterEventHotKey(ref)
        }
        hotKeyHandlers.removeValue(forKey: tag)
    }

    public static func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        hotKeyHandlers.removeAll()
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: hotKeyEventClass,
            eventKind: hotKeyPressedKind
        )

        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(hotKeyParamName),
                EventParamType(hotKeyTypeID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr, hotKeyID.signature == hotKeySignature {
                fireHotKeyHandler(id: hotKeyID.id)
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }
}
