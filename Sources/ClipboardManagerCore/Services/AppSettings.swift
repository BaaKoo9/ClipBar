import Foundation

/// 应用设置的轻量封装，全部存储在 UserDefaults。
public final class AppSettings {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    public enum Keys {
        public static let historyLimit = "historyLimit"
        public static let ignoredApps = "ignoredApps"
        public static let autoPasteEnabled = "autoPasteEnabled"
        public static let hotKeyCode = "hotKeyCode"
        public static let hotKeyModifiers = "hotKeyModifiers"
        public static let enqueueHotKeyCode = "enqueueHotKeyCode"
        public static let enqueueHotKeyModifiers = "enqueueHotKeyModifiers"
        public static let dequeueHotKeyCode = "dequeueHotKeyCode"
        public static let dequeueHotKeyModifiers = "dequeueHotKeyModifiers"
    }

    private init() {}

    /// 历史条数上限（默认 5000）。
    public var historyLimit: Int {
        get {
            let value = defaults.integer(forKey: Keys.historyLimit)
            return value > 0 ? value : 2000
        }
        set { defaults.set(newValue, forKey: Keys.historyLimit) }
    }

    /// 复制时忽略的应用 bundle identifier 列表。
    public var ignoredApps: [String] {
        get { defaults.stringArray(forKey: Keys.ignoredApps) ?? [] }
        set { defaults.set(newValue, forKey: Keys.ignoredApps) }
    }

    /// 从历史粘贴时是否自动注入 ⌘V。
    public var autoPasteEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoPasteEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoPasteEnabled) }
    }

    /// 呼出面板快捷键：keyCode（默认 9 = V）。
    public var hotKeyCode: Int {
        get { defaults.object(forKey: Keys.hotKeyCode) as? Int ?? 9 }
        set { defaults.set(newValue, forKey: Keys.hotKeyCode) }
    }

    /// 呼出面板快捷键：Carbon modifier 位掩码（默认 ⌥⌘ = 2048 | 256）。
    public var hotKeyModifiers: UInt {
        get { defaults.object(forKey: Keys.hotKeyModifiers) as? UInt ?? (2048 | 256) }
        set { defaults.set(newValue, forKey: Keys.hotKeyModifiers) }
    }

    /// 入队复制快捷键：keyCode（默认 14 = E）。
    public var enqueueHotKeyCode: Int {
        get { defaults.object(forKey: Keys.enqueueHotKeyCode) as? Int ?? 14 }
        set { defaults.set(newValue, forKey: Keys.enqueueHotKeyCode) }
    }

    /// 入队复制快捷键：Carbon modifier 位掩码（默认 ⌥⌘ = 2304）。
    public var enqueueHotKeyModifiers: UInt {
        get { defaults.object(forKey: Keys.enqueueHotKeyModifiers) as? UInt ?? (2048 | 256) }
        set { defaults.set(newValue, forKey: Keys.enqueueHotKeyModifiers) }
    }

    /// 出队粘贴快捷键：keyCode（默认 2 = D）。
    public var dequeueHotKeyCode: Int {
        get { defaults.object(forKey: Keys.dequeueHotKeyCode) as? Int ?? 2 }
        set { defaults.set(newValue, forKey: Keys.dequeueHotKeyCode) }
    }

    /// 出队粘贴快捷键：Carbon modifier 位掩码（默认 ⌥⌘ = 2304）。
    public var dequeueHotKeyModifiers: UInt {
        get { defaults.object(forKey: Keys.dequeueHotKeyModifiers) as? UInt ?? (2048 | 256) }
        set { defaults.set(newValue, forKey: Keys.dequeueHotKeyModifiers) }
    }
}
