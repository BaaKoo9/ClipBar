import Carbon
import Foundation

// 文件级状态：Carbon 的 C 回调不能捕获类型上下文，因此用全局变量承载。
private var hotKeyHandler: (() -> Void)?
private var hotKeyRef: EventHotKeyRef?
private var eventHandlerRef: EventHandlerRef?

// 四字符常量（避免 Carbon 宏在 Swift 中的兼容问题）
private let hotKeyEventClass: OSType = 0x6B657962 // 'keyb'
private let hotKeyPressedKind: UInt32 = 1
private let hotKeyTypeID: OSType = 0x686B6964 // 'hkid'
private let hotKeyParamName: UInt32 = 0x6469726F // 'diro'
private let hotKeySignature: OSType = 0x434D484B // 'CMHK'

private func fireHotKeyHandler() {
    DispatchQueue.main.async {
        hotKeyHandler?()
    }
}

/// 全局快捷键服务（Carbon RegisterEventHotKey，无需辅助功能权限）。
public final class HotKeyService {
    public static let shared = HotKeyService()

    private init() {
        installEventHandler()
    }

    deinit {
        HotKeyService.unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    /// 注册全局快捷键；重复调用会先注销旧的。返回是否注册成功。
    
    public func register(keyCode: Int, modifiers: UInt, handler: @escaping () -> Void) -> Bool {
        Self.unregister()
        hotKeyHandler = handler

        var hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            print("RegisterEventHotKey 失败: \(status)")
            hotKeyHandler = nil
            return false
        }
        return true
    }

    public static func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        hotKeyHandler = nil
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
                fireHotKeyHandler()
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
