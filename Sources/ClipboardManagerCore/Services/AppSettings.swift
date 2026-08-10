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
        public static let retentionEnabled = "retentionEnabled"
        public static let retentionDays = "retentionDays"
        public static let bumpOnPaste = "bumpOnPaste"
        public static let lastUpdateCheckAt = "lastUpdateCheckAt"
        public static let availableUpdateVersion = "availableUpdateVersion"
        public static let dismissedUpdateVersion = "dismissedUpdateVersion"
    }

    private init() {}

    /// 历史条数上限（未配置时默认 1000）。
    public var historyLimit: Int {
        get {
            let value = defaults.integer(forKey: Keys.historyLimit)
            return value > 0 ? value : 1000
        }
        set { defaults.set(newValue, forKey: Keys.historyLimit) }
    }

    /// 是否启用按天自动清理（默认关闭）。
    public var retentionEnabled: Bool {
        get { defaults.object(forKey: Keys.retentionEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.retentionEnabled) }
    }

    /// 超过该天数未使用（updated_at）的未置顶条目将被删除；范围 1…30，默认展示值 7。
    public var retentionDays: Int {
        get {
            let value = defaults.integer(forKey: Keys.retentionDays)
            if value <= 0 { return 7 }
            return min(max(value, 1), 30)
        }
        set { defaults.set(min(max(newValue, 1), 30), forKey: Keys.retentionDays) }
    }

    /// 粘贴后是否把该条目的 updated_at 提前（默认开，对齐 Maccy）。
    public var bumpOnPaste: Bool {
        get { defaults.object(forKey: Keys.bumpOnPaste) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.bumpOnPaste) }
    }

    /// 上次静默检查更新的时间戳（unix）。
    public var lastUpdateCheckAt: TimeInterval {
        get { defaults.double(forKey: Keys.lastUpdateCheckAt) }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheckAt) }
    }

    /// 已发现但尚未安装的远程版本号（空表示无）。
    public var availableUpdateVersion: String? {
        get {
            let value = defaults.string(forKey: Keys.availableUpdateVersion) ?? ""
            return value.isEmpty ? nil : value
        }
        set { defaults.set(newValue ?? "", forKey: Keys.availableUpdateVersion) }
    }

    /// 用户点「稍后」静默的版本号。
    public var dismissedUpdateVersion: String? {
        get {
            let value = defaults.string(forKey: Keys.dismissedUpdateVersion) ?? ""
            return value.isEmpty ? nil : value
        }
        set { defaults.set(newValue ?? "", forKey: Keys.dismissedUpdateVersion) }
    }

    /// 是否应向用户展示「有更新」提示（排除已静默版本）。
    public var shouldSurfaceUpdate: Bool {
        guard let available = availableUpdateVersion, !available.isEmpty else { return false }
        return available != dismissedUpdateVersion
    }

    /// 复制时忽略的应用 bundle identifier 列表。
    public var ignoredApps: [String] {
        get { defaults.stringArray(forKey: Keys.ignoredApps) ?? [] }
        set { defaults.set(newValue, forKey: Keys.ignoredApps) }
    }

    /// 从历史粘贴时是否自动注入 ⌘V。
    public var autoPasteEnabled: Bool {
        get { defaults.object(forKey: Keys.autoPasteEnabled) as? Bool ?? true }
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
