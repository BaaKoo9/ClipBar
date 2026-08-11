import AppKit
import ClipboardManagerCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case shortcuts = "快捷键"
        case general = "通用"
        case privacy = "隐私"
        case labels = "标签"
        case updates = "更新"
        case data = "数据"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .shortcuts: return "keyboard"
            case .general: return "gearshape"
            case .privacy: return "hand.raised"
            case .labels: return "tag"
            case .updates: return "arrow.triangle.2.circlepath"
            case .data: return "externaldrive"
            }
        }
    }

    @State private var selectedPane: Pane = .shortcuts
    @State private var hotKeyCode: Int
    @State private var hotKeyModifiers: UInt
    @State private var enqueueHotKeyCode: Int
    @State private var enqueueHotKeyModifiers: UInt
    @State private var dequeueHotKeyCode: Int
    @State private var dequeueHotKeyModifiers: UInt
    @State private var historyLimit: Int
    @State private var retentionEnabled: Bool
    @State private var retentionDays: Int
    @State private var autoPaste: Bool
    @State private var bumpOnPaste: Bool
    @State private var launchAtLogin: Bool
    @State private var ignoredApps: [String]
    @State private var showAppPicker = false
    @State private var showClearConfirm = false
    @State private var labels: [ClipboardLabel] = []
    @State private var newLabelName = ""
    @State private var newLabelColor = "blue"
    @State private var availableUpdateVersion: String?
    @State private var lastUpdateCheckAt: TimeInterval = 0
    @State private var retentionDaysText: String
    @State private var labelPendingDelete: ClipboardLabel?
    @State private var generalDirty = false
    @State private var generalSaveFlash = false
    @FocusState private var retentionFieldFocused: Bool
    @ObservedObject private var updateProgress = UpdateProgressModel.shared

    init() {
        let settings = AppSettings.shared
        _hotKeyCode = State(initialValue: settings.hotKeyCode)
        _hotKeyModifiers = State(initialValue: settings.hotKeyModifiers)
        _enqueueHotKeyCode = State(initialValue: settings.enqueueHotKeyCode)
        _enqueueHotKeyModifiers = State(initialValue: settings.enqueueHotKeyModifiers)
        _dequeueHotKeyCode = State(initialValue: settings.dequeueHotKeyCode)
        _dequeueHotKeyModifiers = State(initialValue: settings.dequeueHotKeyModifiers)
        _historyLimit = State(initialValue: settings.historyLimit)
        _retentionEnabled = State(initialValue: settings.retentionEnabled)
        _retentionDays = State(initialValue: settings.retentionDays)
        _retentionDaysText = State(initialValue: "\(settings.retentionDays)")
        _autoPaste = State(initialValue: settings.autoPasteEnabled)
        _bumpOnPaste = State(initialValue: settings.bumpOnPaste)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
        _ignoredApps = State(initialValue: settings.ignoredApps)
        _availableUpdateVersion = State(initialValue: settings.shouldSurfaceUpdate ? settings.availableUpdateVersion : nil)
        _lastUpdateCheckAt = State(initialValue: settings.lastUpdateCheckAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 140)
                Divider()
                ScrollView {
                    Group {
                        switch selectedPane {
                        case .shortcuts: shortcutSection
                        case .general: generalSection
                        case .privacy: privacySection
                        case .labels: labelsSection
                        case .updates: updatesSection
                        case .data: dangerSection
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(width: 720, height: 560)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 40, y: 14)
        .onAppear {
            reloadLabels()
            refreshUpdateState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardLabelsDidChange)) { _ in
            reloadLabels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardUpdateAvailable)) { _ in
            refreshUpdateState()
        }
    }

    // MARK: - 标题栏 / 侧栏

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text("ClipBar 设置")
                .font(.system(size: 14, weight: .semibold))

            if AppSettings.shared.shouldSurfaceUpdate {
                Text("有更新")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange, in: Capsule())
            }

            Spacer()

            Button {
                NSApp.keyWindow?.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Pane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 16)
                        Text(pane.rawValue)
                            .font(.system(size: 12, weight: selectedPane == pane ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if pane == .updates, AppSettings.shared.shouldSurfaceUpdate {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .foregroundStyle(selectedPane == pane ? Color.white : Color.primary.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedPane == pane ? Color.accentColor : Color.primary.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            Spacer()
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("全局快捷键")

            if !HotKeyService.isAccessibilityAvailable || !HotKeyService.isListeningAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("全局快捷键需要「辅助功能」和「输入监控」权限")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("去开启") {
                        openAccessibilityPermissionSettings()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }

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

    private func openAccessibilityPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("通用")

            Toggle("开机时自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, _ in
                    generalDirty = true
                    generalSaveFlash = false
                }

            HStack {
                Text("历史条数上限")
                Spacer()
                Picker("", selection: $historyLimit) {
                    Text("100").tag(100)
                    Text("300").tag(300)
                    Text("500").tag(500)
                    Text("1,000").tag(1000)
                    Text("2,000").tag(2000)
                    Text("3,000").tag(3000)
                }
                .labelsHidden()
                .frame(width: 110)
                .onChange(of: historyLimit) { _, _ in
                    generalDirty = true
                    generalSaveFlash = false
                }
            }

            Toggle("自动清理过期内容", isOn: $retentionEnabled)
                .onChange(of: retentionEnabled) { _, _ in
                    generalDirty = true
                    generalSaveFlash = false
                }

            if retentionEnabled {
                HStack(spacing: 8) {
                    Text("保留天数")
                    Spacer()
                    TextField("", text: $retentionDaysText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .focused($retentionFieldFocused)
                        .onChange(of: retentionDaysText) { _, text in
                            generalDirty = true
                            generalSaveFlash = false
                            if let days = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                               (1...90).contains(days) {
                                retentionDays = days
                            }
                        }
                    Text("天")
                        .foregroundStyle(.secondary)
                    Stepper("", value: $retentionDays, in: 1...90)
                        .labelsHidden()
                        .onChange(of: retentionDays) { _, days in
                            retentionDaysText = "\(days)"
                            generalDirty = true
                            generalSaveFlash = false
                        }
                }
                Text("超过该天数未使用的未置顶条目将自动删除；置顶不受影响。可输入 1–90。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Toggle("粘贴后移到最前", isOn: $bumpOnPaste)
                .onChange(of: bumpOnPaste) { _, _ in
                    generalDirty = true
                    generalSaveFlash = false
                }
            Text("从历史粘贴后，将该条目提前到未置顶列表顶部（类似 Maccy 默认行为）。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("选中后自动粘贴", isOn: $autoPaste)
                    .onChange(of: autoPaste) { _, _ in
                        generalDirty = true
                        generalSaveFlash = false
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

            Divider()
                .padding(.top, 4)

            HStack(spacing: 10) {
                if generalSaveFlash {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Spacer()
                Button {
                    saveGeneralSettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: generalSaveFlash ? "checkmark" : "square.and.arrow.down")
                        Text(generalSaveFlash ? "已保存" : "保存设置")
                    }
                    .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled((!generalDirty && !generalSaveFlash) || !isRetentionDaysValid)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.top, 4)
            .animation(.easeOut(duration: 0.18), value: generalSaveFlash)
        }
    }

    private var isRetentionDaysValid: Bool {
        guard retentionEnabled else { return true }
        guard let days = Int(retentionDaysText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return (1...90).contains(days)
    }

    private func saveGeneralSettings() {
        if retentionEnabled {
            guard let days = Int(retentionDaysText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...90).contains(days) else { return }
            retentionDays = days
            retentionDaysText = "\(days)"
        }

        retentionFieldFocused = false
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }

        setLaunchAtLogin(launchAtLogin)
        AppSettings.shared.historyLimit = historyLimit
        AppSettings.shared.retentionEnabled = retentionEnabled
        AppSettings.shared.retentionDays = retentionDays
        AppSettings.shared.bumpOnPaste = bumpOnPaste
        AppSettings.shared.autoPasteEnabled = autoPaste
        ClipboardStore.shared.enforceHistoryLimit { _ in
            NotificationCenter.default.post(name: .clipboardHistoryLimitChanged, object: nil)
        }
        generalDirty = false
        withAnimation(.easeOut(duration: 0.18)) {
            generalSaveFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) {
                generalSaveFlash = false
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
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("隐私")

            Text("忽略名单中的应用，其复制内容不会写入历史。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            // 快捷推荐：密码管理器等敏感 App
            if !suggestedIgnoredApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("推荐忽略")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestedIgnoredApps) { app in
                            Button {
                                addIgnoredApp(app.bundleID)
                            } label: {
                                HStack(spacing: 5) {
                                    AppIconView(icon: app.icon, size: 14)
                                    Text(app.name)
                                        .font(.system(size: 11))
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    showAppPicker = true
                } label: {
                    Label("从应用列表添加…", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAppPicker, arrowEdge: .bottom) {
                    AppPickerPopover(excludedBundleIDs: Set(ignoredApps)) { bundleID in
                        addIgnoredApp(bundleID)
                        showAppPicker = false
                    }
                }

                Button {
                    if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        addIgnoredApp(bundleID)
                    }
                } label: {
                    Label("添加当前前台 App", systemImage: "macwindow")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if ignoredApps.isEmpty {
                Text("尚未忽略任何应用")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(ignoredApps, id: \.self) { bundleID in
                        let info = AppCatalog.info(for: bundleID)
                        HStack(spacing: 10) {
                            AppIconView(icon: info.icon, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(info.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(bundleID)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button {
                                ignoredApps.removeAll { $0 == bundleID }
                                saveIgnoredApps()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("移除")
                        }
                        .padding(.vertical, 6)
                        if bundleID != ignoredApps.last {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            }

            Text("所有数据仅保存在本机，应用没有任何网络权限。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    /// 本机已安装、且尚未加入忽略名单的常见敏感应用。
    private var suggestedIgnoredApps: [AppCatalog.AppInfo] {
        AppCatalog.commonSensitiveBundleIDs
            .filter { !ignoredApps.contains($0) }
            .compactMap { id -> AppCatalog.AppInfo? in
                let info = AppCatalog.info(for: id)
                // 只推荐本机确实存在的 App，避免一排无效按钮
                guard AppCatalog.isInstalled(bundleID: id) else { return nil }
                return info
            }
    }

    private func addIgnoredApp(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !ignoredApps.contains(id) else { return }
        ignoredApps.append(id)
        saveIgnoredApps()
    }

    private func saveIgnoredApps() {
        AppSettings.shared.ignoredApps = ignoredApps
    }

    // MARK: - 标签

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("自定义标签")
            Text("可为历史条目打多个标签，在面板筛选或搜索 #标签名。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("新标签名称", text: $newLabelName)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        let name = newLabelName
                        ClipboardStore.shared.createLabel(name: name, color: newLabelColor) { _ in
                            newLabelName = ""
                            reloadLabels()
                        }
                    }
                    .disabled(newLabelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                colorSwatches(selection: $newLabelColor)
            }

            if labels.isEmpty {
                Text("还没有标签")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(labels) { label in
                        HStack(spacing: 10) {
                            // 列表只保留标记色；点击可改色
                            ColorDotPicker(selection: Binding(
                                get: { label.color },
                                set: { color in
                                    ClipboardStore.shared.updateLabel(id: label.id, name: nil, color: color) {
                                        reloadLabels()
                                    }
                                }
                            ))
                            Text(label.name)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button(role: .destructive) {
                                labelPendingDelete = label
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("删除标签")
                        }
                        .padding(.vertical, 8)
                        if label.id != labels.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .alert(
            "删除标签",
            isPresented: Binding(
                get: { labelPendingDelete != nil },
                set: { if !$0 { labelPendingDelete = nil } }
            ),
            presenting: labelPendingDelete
        ) { label in
            Button("取消", role: .cancel) { labelPendingDelete = nil }
            Button("删除", role: .destructive) {
                ClipboardStore.shared.deleteLabel(id: label.id) {
                    reloadLabels()
                }
                labelPendingDelete = nil
            }
        } message: { label in
            Text("确定删除「\(label.name)」？已打在条目上的该标签也会移除。")
        }
    }

    private func colorSwatches(selection: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ForEach(ClipboardLabel.presetColors, id: \.self) { color in
                Button {
                    selection.wrappedValue = color
                } label: {
                    Circle()
                        .fill(LabelColor.color(for: color))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(
                                Color.primary.opacity(selection.wrappedValue == color ? 0.55 : 0.12),
                                lineWidth: selection.wrappedValue == color ? 2 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(color)
            }
        }
    }

    private func reloadLabels() {
        ClipboardStore.shared.fetchLabels { result in
            DispatchQueue.main.async {
                labels = result
            }
        }
    }

    // MARK: - 更新

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("软件更新")
            Text("当前版本 \(UpdateChecker.currentVersion)")
                .font(.system(size: 13))

            if updateProgress.isBusy || updateProgress.phase != .idle {
                VStack(alignment: .leading, spacing: 8) {
                    Text(updateProgress.statusText.isEmpty ? "处理中…" : updateProgress.statusText)
                        .font(.system(size: 12, weight: .medium))
                    if case .downloading = updateProgress.phase {
                        ProgressView(value: updateProgress.fractionCompleted)
                            .progressViewStyle(.linear)
                    } else if case .checking = updateProgress.phase {
                        ProgressView()
                            .controlSize(.small)
                    } else if case .installing = updateProgress.phase {
                        ProgressView()
                            .controlSize(.small)
                    } else if case .failed(let message) = updateProgress.phase {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        Button("重试下载") {
                            UpdateChecker.checkForUpdates(interactive: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            if let available = availableUpdateVersion, AppSettings.shared.shouldSurfaceUpdate {
                VStack(alignment: .leading, spacing: 8) {
                    Label("发现新版本 \(available)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                    HStack(spacing: 10) {
                        Button("立即更新") {
                            UpdateChecker.checkForUpdates(interactive: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updateProgress.isBusy)
                        Button("稍后提醒") {
                            AppSettings.shared.dismissedUpdateVersion = available
                            refreshUpdateState()
                            NotificationCenter.default.post(name: .clipboardUpdateAvailable, object: nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(updateProgress.isBusy)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            } else if !updateProgress.isBusy {
                Text("已是最新，或暂无待处理更新。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button("立即检查更新…") {
                UpdateChecker.checkForUpdates(interactive: true)
            }
            .disabled(updateProgress.isBusy)

            if lastUpdateCheckAt > 0 {
                Text("上次检查：\(formattedCheckTime(lastUpdateCheckAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func refreshUpdateState() {
        let settings = AppSettings.shared
        availableUpdateVersion = settings.shouldSurfaceUpdate ? settings.availableUpdateVersion : nil
        lastUpdateCheckAt = settings.lastUpdateCheckAt
    }

    private func formattedCheckTime(_ ts: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    // MARK: - 数据

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("数据")

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
                    ClipboardStore.shared.clear()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - 应用目录 / 忽略名单选择

private enum AppCatalog {
    struct AppInfo: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: String { bundleID }
    }

    /// 竞品常见忽略对象：密码管理器与系统钥匙串相关。
    static let commonSensitiveBundleIDs: [String] = [
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephoneagent",
        "com.dashlane.mac",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.apple.PasswordManager",
        "com.apple.keychainaccess",
        "com.microsoft.CompanyPortalMac"
    ]

    static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func info(for bundleID: String) -> AppInfo {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = localizedName(at: url) ?? URL(fileURLWithPath: url.path).deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            return AppInfo(bundleID: bundleID, name: name, icon: icon)
        }
        // 未安装：用 bundle id 最后一段凑个可读名
        let fallback = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return AppInfo(bundleID: bundleID, name: fallback, icon: nil)
    }

    /// 运行中的常规 App + /Applications 等目录扫描，按名称排序；已忽略的由调用方过滤。
    static func listCandidates(excluding excluded: Set<String>) -> [AppInfo] {
        var byID: [String: AppInfo] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  !excluded.contains(id),
                  !id.hasPrefix("com.apple.WebKit.") else { continue }
            let name = app.localizedName ?? id
            let icon = app.icon
            icon?.size = NSSize(width: 32, height: 32)
            byID[id] = AppInfo(bundleID: id, name: name, icon: icon)
        }

        let directories = applicationDirectories()
        let fm = FileManager.default
        for directory in directories {
            guard let items = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier,
                      !excluded.contains(id),
                      byID[id] == nil else { continue }
                let name = localizedName(at: url) ?? url.deletingPathExtension().lastPathComponent
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 32, height: 32)
                byID[id] = AppInfo(bundleID: id, name: name, icon: icon)
            }
        }

        return byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func applicationDirectories() -> [URL] {
        var urls: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/Applications/Utilities")
        ]
        if let userApps = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            urls.append(userApps)
        }
        return urls
    }

    private static func localizedName(at url: URL) -> String? {
        if let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }
}

private struct AppIconView: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// 简单流式布局：推荐忽略按钮自动换行。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

private struct AppPickerPopover: View {
    let excludedBundleIDs: Set<String>
    var onSelect: (String) -> Void

    @State private var query = ""
    @State private var apps: [AppCatalog.AppInfo] = []
    @State private var loading = true

    private var filtered: [AppCatalog.AppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索应用名称…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(10)

            Divider()

            if loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                Text(query.isEmpty ? "未找到可添加的应用" : "无匹配结果")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { app in
                            Button {
                                onSelect(app.bundleID)
                            } label: {
                                HStack(spacing: 10) {
                                    AppIconView(icon: app.icon, size: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(app.bundleID)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .frame(width: 320, height: 360)
        .task {
            // 扫盘放后台，避免弹层卡顿
            let excluded = excludedBundleIDs
            let list = await Task.detached(priority: .userInitiated) {
                AppCatalog.listCandidates(excluding: excluded)
            }.value
            apps = list
            loading = false
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

/// 列表行标记色：色点始终可见，点击弹出选色。
private struct ColorDotPicker: View {
    @Binding var selection: String
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Circle()
                .fill(LabelColor.color(for: selection))
                .frame(width: 12, height: 12)
                .overlay(
                    Circle().stroke(Color.primary.opacity(0.22), lineWidth: 1)
                )
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("更改颜色")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                ForEach(ClipboardLabel.presetColors, id: \.self) { color in
                    Button {
                        selection = color
                        showPicker = false
                    } label: {
                        Circle()
                            .fill(LabelColor.color(for: color))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().stroke(
                                    Color.primary.opacity(selection == color ? 0.55 : 0.12),
                                    lineWidth: selection == color ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(color)
                }
            }
            .padding(10)
        }
    }
}

extension Notification.Name {
    static let clipboardHotKeyChanged = Notification.Name("clipboardHotKeyChanged")
    static let clipboardHistoryLimitChanged = Notification.Name("clipboardHistoryLimitChanged")
}
