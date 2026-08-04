import AppKit
import ClipboardManagerCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: PanelViewModel

    @State private var hotKeyCode: Int
    @State private var hotKeyModifiers: UInt
    @State private var enqueueHotKeyCode: Int
    @State private var enqueueHotKeyModifiers: UInt
    @State private var dequeueHotKeyCode: Int
    @State private var dequeueHotKeyModifiers: UInt
    @State private var historyLimit: Int
    @State private var autoPaste: Bool
    @State private var launchAtLogin: Bool
    @State private var ignoredApps: [String]
    @State private var ignoredAppInput = ""
    @State private var showClearConfirm = false

    init(viewModel: PanelViewModel) {
        self.viewModel = viewModel
        let settings = AppSettings.shared
        _hotKeyCode = State(initialValue: settings.hotKeyCode)
        _hotKeyModifiers = State(initialValue: settings.hotKeyModifiers)
        _enqueueHotKeyCode = State(initialValue: settings.enqueueHotKeyCode)
        _enqueueHotKeyModifiers = State(initialValue: settings.enqueueHotKeyModifiers)
        _dequeueHotKeyCode = State(initialValue: settings.dequeueHotKeyCode)
        _dequeueHotKeyModifiers = State(initialValue: settings.dequeueHotKeyModifiers)
        _historyLimit = State(initialValue: settings.historyLimit)
        _autoPaste = State(initialValue: settings.autoPasteEnabled)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
        _ignoredApps = State(initialValue: settings.ignoredApps)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    shortcutSection
                    generalSection
                    privacySection
                    dangerSection
                }
                .padding(14)
            }
        }
        .frame(width: 860, height: 190)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.showsSettings = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Text("设置")
                .font(.system(size: 14, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("全局快捷键")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ShortcutRecorder(
                title: "呼出面板",
                keyCode: $hotKeyCode,
                modifiers: $hotKeyModifiers,
                onChange: notifyHotKeyChanged
            )
            ShortcutRecorder(
                title: "入队复制",
                keyCode: $enqueueHotKeyCode,
                modifiers: $enqueueHotKeyModifiers,
                onChange: notifyHotKeyChanged
            )
            ShortcutRecorder(
                title: "出队粘贴",
                keyCode: $dequeueHotKeyCode,
                modifiers: $dequeueHotKeyModifiers,
                onChange: notifyHotKeyChanged
            )

            Text("入队复制把当前剪贴板内容加入粘贴队列；出队粘贴把队列下一条写回剪贴板并粘贴。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func notifyHotKeyChanged() {
        let settings = AppSettings.shared
        settings.hotKeyCode = hotKeyCode
        settings.hotKeyModifiers = hotKeyModifiers
        settings.enqueueHotKeyCode = enqueueHotKeyCode
        settings.enqueueHotKeyModifiers = enqueueHotKeyModifiers
        settings.dequeueHotKeyCode = dequeueHotKeyCode
        settings.dequeueHotKeyModifiers = dequeueHotKeyModifiers
        NotificationCenter.default.post(name: .clipboardHotKeyChanged, object: nil)
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("通用")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("开机时自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }

            HStack {
                Text("历史条数上限")
                Spacer()
                Picker("", selection: $historyLimit) {
                    Text("1,000").tag(1000)
                    Text("3,000").tag(3000)
                    Text("5,000").tag(5000)
                    Text("10,000").tag(10000)
                    Text("20,000").tag(20000)
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: historyLimit) { _, newValue in
                    AppSettings.shared.historyLimit = newValue
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("选中后自动粘贴", isOn: $autoPaste)
                    .onChange(of: autoPaste) { _, enabled in
                        AppSettings.shared.autoPasteEnabled = enabled
                    }

                if autoPaste && !PasteService.hasAccessibilityPermission {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("自动粘贴需要辅助功能权限")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("去开启") {
                            openAccessibilitySettings()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("登录项设置失败: \(error)")
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 隐私

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("隐私")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("App Bundle ID，如 com.apple.PasswordManager", text: $ignoredAppInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                Button("添加") {
                    addIgnoredApp()
                }
                .font(.system(size: 12))
                .disabled(ignoredAppInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                   !ignoredApps.contains(bundleID) {
                    ignoredApps.append(bundleID)
                    saveIgnoredApps()
                }
            } label: {
                Label("添加当前前台 App", systemImage: "app.badge")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if !ignoredApps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(ignoredApps, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                ignoredApps.removeAll { $0 == bundleID }
                                saveIgnoredApps()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 5)
                        if bundleID != ignoredApps.last {
                            Divider()
                        }
                    }
                }
            }

            Text("这些 App 复制的内容不会被记录，适合密码管理器等敏感场景。所有数据仅保存在本机，应用没有任何网络权限。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineSpacing(2)
        }
    }

    private func addIgnoredApp() {
        let id = ignoredAppInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !ignoredApps.contains(id) else { return }
        ignoredApps.append(id)
        ignoredAppInput = ""
        saveIgnoredApps()
    }

    private func saveIgnoredApps() {
        AppSettings.shared.ignoredApps = ignoredApps
    }

    // MARK: - 危险操作

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("数据")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清空全部历史", systemImage: "trash")
                    .font(.system(size: 13))
            }
            .confirmationDialog(
                "确定清空全部剪贴板历史吗？此操作不可撤销。",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清空全部历史", role: .destructive) {
                    viewModel.clearAllHistory()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

// MARK: - 快捷键录制行

private struct ShortcutRecorder: View {
    let title: String
    @Binding var keyCode: Int
    @Binding var modifiers: UInt
    var onChange: () -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    private var displayText: String {
        KeyCodeMapper.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            Button {
                startRecording()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isRecording ? "record.circle" : "keyboard")
                        .font(.system(size: 11))
                        .foregroundStyle(isRecording ? .red : .secondary)
                    Text(isRecording ? "按下新组合键…（Esc 取消）" : displayText)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .onDisappear {
            removeMonitor()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isRecording else { return event }

            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }

            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isEmpty else { return nil }

            // 排除导航键与编辑键（方向键、Home/End/翻页、Esc/Return/Tab）
            let blockedKeyCodes: Set<Int> = [48, 53, 36, 115, 116, 117, 119, 121, 123, 124, 125, 126]
            guard !blockedKeyCodes.contains(Int(event.keyCode)) else { return nil }

            self.keyCode = Int(event.keyCode)
            self.modifiers = KeyCodeMapper.carbonModifiers(from: flags)
            self.stopRecording()
            self.onChange()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

extension Notification.Name {
    static let clipboardHotKeyChanged = Notification.Name("clipboardHotKeyChanged")
}
