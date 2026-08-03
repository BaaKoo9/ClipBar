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
    }

    private init() {}

    /// 历史条数上限（默认 5000）。
    public var historyLimit: Int {
        get {
            let value = defaults.integer(forKey: Keys.historyLimit)
            return value > 0 ? value : 5000
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

    /// 全局快捷键：keyCode（默认 9 = V）。
    public var hotKeyCode: Int {
        get {
            let value = defaults.object(forKey: Keys.hotKeyCode) as? Int
            return value ?? 9
        }
        set { defaults.set(newValue, forKey: Keys.hotKeyCode) }
    }

    /// 全局快捷键：Carbon modifier 位掩码（默认 ⌥⌘ = 2048 | 256）。
    public var hotKeyModifiers: UInt {
        get {
            let value = defaults.object(forKey: Keys.hotKeyModifiers) as? UInt
            // Carbon 修饰键：kCommandKey = 1 << 8 = 256, kOptionKey = 1 << 11 = 2048
            return value ?? (2048 | 256)
        }
        set { defaults.set(newValue, forKey: Keys.hotKeyModifiers) }
    }
}
