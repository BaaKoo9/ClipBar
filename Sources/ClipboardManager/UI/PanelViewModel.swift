import AppKit
import ClipboardManagerCore
import Foundation
import SwiftUI

/// 面板的共享状态：历史数据、选中项、搜索、粘贴队列与 Toast。
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var items: [ClipboardItem] = []
    @Published var selectedID: Int64?
    @Published var pasteQueue: [ClipboardItem] = []
    @Published var filterKind: ClipboardItem.Kind?
    @Published var filterLabelID: Int64?
    @Published var labels: [ClipboardLabel] = []
    private(set) var scrollRequestID: Int64?
    /// 递增以强制触发滚动（即使目标 id 未变，呼出时需滚回起点）。
    @Published private(set) var scrollGeneration: UInt = 0
    /// 每次呼出都把键盘焦点还给面板，避免搜索框激活输入法时同步阻塞主线程。
    @Published private(set) var panelFocusGeneration: UInt = 0
    /// 本次滚动是否使用动画。
    private(set) var scrollAnimated = true
    /// 底部提示中的入队/出队快捷键文案，随设置变更同步。
    @Published var enqueueHotKeyLabel = ""
    @Published var dequeueHotKeyLabel = ""
    /// 库里的总条数（不受首屏分页影响）。
    @Published private(set) var libraryCount = 0
    /// 当前筛选/搜索的匹配条数（同样不带 LIMIT）。
    @Published private(set) var matchCount = 0
    /// 控制分页哨兵与异步回调只在当前面板会话内生效。
    @Published private(set) var isPanelOpen = false

    /// AppDelegate 注入：请求关闭面板（Esc、粘贴完成后等），参数为是否播放淡出动画。
    var onRequestClose: ((Bool) -> Void)?
    /// AppDelegate 注入：请求打开独立设置窗口。
    var onOpenSettings: (() -> Void)?

    func requestClose(animated: Bool = true) {
        onRequestClose?(animated)
    }

    private var loaded = false
    private var targetPID: pid_t?
    private var searchWorkItem: DispatchWorkItem?
    private var filterWorkItem: DispatchWorkItem?
    private let enqueueQueue = DispatchQueue(label: "com.huxiaolong.clipboard.enqueue")
    private var hotKeyObserver: NSObjectProtocol?
    private var historyLimitObserver: NSObjectProtocol?
    private var historyChangeObserver: NSObjectProtocol?
    private var labelsChangeObserver: NSObjectProtocol?
    /// 呼出首帧关闭列表/滚动动画，避免「先旧后新」的一帧卡顿。
    /// 这是一次操作内的事务标记，不是界面内容；发布它会让整棵面板视图额外失效。
    private(set) var suppressListAnimation = false
    private var refreshInFlight = false
    private var refreshPendingForceSelectFirst: Bool?
    private var loadMoreInFlight = false
    private var listGeneration = 0
    private var lastRefreshAt: CFAbsoluteTime = 0
    private var lastRefreshKind: ClipboardItem.Kind?
    private var lastRefreshLabelID: Int64?
    private var lastRefreshQuery = ""

    /// 首屏与每次向右续页的条数；全库仍可搜、可滚到。
    private static let pageSize = 40

    init() {
        refreshHotKeyLabels()
        loadLabels()
        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHotKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshHotKeyLabels()
            }
        }
        historyLimitObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryLimitChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(forceSelectFirst: false)
            }
        }
        historyChangeObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.loaded else { return }
                self.refresh(forceSelectFirst: false)
            }
        }
        labelsChangeObserver = NotificationCenter.default.addObserver(
            forName: .clipboardLabelsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.loadLabels()
            }
        }
    }

    deinit {
        if let hotKeyObserver {
            NotificationCenter.default.removeObserver(hotKeyObserver)
        }
        if let historyLimitObserver {
            NotificationCenter.default.removeObserver(historyLimitObserver)
        }
        if let historyChangeObserver {
            NotificationCenter.default.removeObserver(historyChangeObserver)
        }
        if let labelsChangeObserver {
            NotificationCenter.default.removeObserver(labelsChangeObserver)
        }
    }

    func refreshHotKeyLabels() {
        let settings = AppSettings.shared
        enqueueHotKeyLabel = KeyCodeMapper.displayString(
            keyCode: settings.enqueueHotKeyCode,
            modifiers: settings.enqueueHotKeyModifiers
        )
        dequeueHotKeyLabel = KeyCodeMapper.displayString(
            keyCode: settings.dequeueHotKeyCode,
            modifiers: settings.dequeueHotKeyModifiers
        )
    }

    func loadHistory() {
        guard !loaded else { return }
        loaded = true
        refresh(forceSelectFirst: true) { [weak self] in
            ClipboardStore.shared.enforceHistoryLimit { changed in
                DebugLog.write("启动清理 changed=\(changed)")
                guard changed else { return }
                self?.refresh(forceSelectFirst: false)
            }
        }
    }

    /// 面板显示前调用：记住前台 App，并同步重置筛选/选中，保证首帧内容已就绪。
    func panelWillOpen(from pid: pid_t?) {
        isPanelOpen = true
        panelFocusGeneration &+= 1
        targetPID = pid
        suppressListAnimation = true
        filterWorkItem?.cancel()
        searchWorkItem?.cancel()
        filterKind = nil
        filterLabelID = nil
        if !searchText.isEmpty { searchText = "" }
        refreshHotKeyLabels()
        // 先用已有缓存选中首条，并无动画滚回列表起点
        if loaded, let first = items.first {
            selectedID = first.id
            requestScroll(to: first.id, animated: false)
        }
    }

    func requestScroll(to id: Int64?, animated: Bool) {
        scrollAnimated = animated
        scrollRequestID = id
        scrollGeneration &+= 1
    }

    /// 面板呼出后：热缓存已是默认首屏则跳过刷新。
    func panelDidOpen() {
        let openStarted = CFAbsoluteTimeGetCurrent()
        let finishOpen: () -> Void = { [weak self] in
            guard let self else { return }
            let ms = Int((CFAbsoluteTimeGetCurrent() - openStarted) * 1000)
            DebugLog.write("呼出就绪 \(ms)ms items=\(self.items.count)")
            // 再等两帧再开动画，避免首帧布局和悬停抢主线程
            DispatchQueue.main.async { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.suppressListAnimation = false
                }
            }
        }

        if canReuseOpenCache {
            DebugLog.write("呼出跳过刷新 cache=\(self.items.count)")
            finishOpen()
        } else if loaded {
            refresh(forceSelectFirst: true, completion: finishOpen)
        } else {
            loadHistory()
            finishOpen()
        }
    }

    func panelDidClose() {
        guard isPanelOpen else {
            DebugLog.write("忽略重复 panelDidClose")
            return
        }
        isPanelOpen = false
        let wasRefreshInFlight = refreshInFlight
        invalidateListRequests()
        searchWorkItem?.cancel()
        filterWorkItem?.cancel()
        let hadActiveFilter = filterKind != nil
            || filterLabelID != nil
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !searchText.isEmpty {
            searchText = ""
        }
        filterKind = nil
        filterLabelID = nil
        if items.count > Self.pageSize {
            items = Array(items.prefix(Self.pageSize))
        }
        // 写入和设置变更已经负责容量清理；关闭面板只预热被筛选/中断的默认首屏。
        if hadActiveFilter || wasRefreshInFlight {
            refresh(forceSelectFirst: false)
        }
    }

    /// 关闭面板时让所有旧列表回调失效，避免续页在裁回首屏后再次追加。
    private func invalidateListRequests() {
        listGeneration &+= 1
        refreshInFlight = false
        refreshPendingForceSelectFirst = nil
        loadMoreInFlight = false
    }

    /// 启动或上次刷新已拉过默认全量，且历史变更会走通知时，呼出不必再打库。
    private var canReuseOpenCache: Bool {
        loaded
            && !items.isEmpty
            && lastRefreshKind == nil
            && lastRefreshLabelID == nil
            && lastRefreshQuery.isEmpty
            && filterKind == nil
            && filterLabelID == nil
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 搜索与筛选

    /// 输入过程中防抖，避免每个按键都触发一次全表 LIKE 查询。
    func searchDidChange() {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(forceSelectFirst: true) }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    func setFilter(_ kind: ClipboardItem.Kind?) {
        filterKind = kind
        scheduleFilterRefresh(kind: kind)
    }

    func setLabelFilter(_ labelID: Int64?) {
        filterLabelID = labelID
        scheduleFilterRefresh(kind: filterKind)
    }

    private func scheduleFilterRefresh(kind: ClipboardItem.Kind?) {
        filterWorkItem?.cancel()
        let started = CFAbsoluteTimeGetCurrent()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh(forceSelectFirst: true) {
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                DebugLog.write(
                    "筛选刷新 \(ms)ms kind=\(kind?.rawValue ?? "all") label=\(self?.filterLabelID.map(String.init) ?? "-")"
                )
            }
        }
        filterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    func loadLabels() {
        ClipboardStore.shared.fetchLabels { [weak self] labels in
            DispatchQueue.main.async {
                self?.labels = labels
            }
        }
    }

    func toggleLabel(_ labelID: Int64, for item: ClipboardItem) {
        ClipboardStore.shared.toggleItemLabel(itemID: item.id, labelID: labelID) { [weak self] in
            DispatchQueue.main.async {
                self?.refresh(forceSelectFirst: false)
            }
        }
    }

    func createLabel(name: String, color: String = "blue") {
        ClipboardStore.shared.createLabel(name: name, color: color) { [weak self] _ in
            DispatchQueue.main.async {
                self?.loadLabels()
            }
        }
    }

    func updateLabel(id: Int64, name: String?, color: String?) {
        ClipboardStore.shared.updateLabel(id: id, name: name, color: color) { [weak self] in
            DispatchQueue.main.async {
                self?.loadLabels()
            }
        }
    }

    func deleteLabel(id: Int64) {
        ClipboardStore.shared.deleteLabel(id: id) { [weak self] in
            DispatchQueue.main.async {
                if self?.filterLabelID == id {
                    self?.filterLabelID = nil
                }
                self?.loadLabels()
                self?.refresh(forceSelectFirst: false)
            }
        }
    }

    /// 拖拽过程中的即时重排（仅更新内存；松手后再落库）。
    func moveLabel(draggingID: Int64, before targetID: Int64?) {
        guard let from = labels.firstIndex(where: { $0.id == draggingID }) else { return }
        var ordered = labels
        if let targetID {
            guard let to = ordered.firstIndex(where: { $0.id == targetID }), from != to else { return }
            ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        } else {
            guard from != ordered.count - 1 else { return }
            let item = ordered.remove(at: from)
            ordered.append(item)
        }
        labels = ordered
    }

    func commitLabelOrder() {
        ClipboardStore.shared.reorderLabels(orderedIDs: labels.map(\.id))
    }

    var canLoadMore: Bool {
        isPanelOpen && !refreshInFlight && !loadMoreInFlight && items.count < matchCount
    }

    var historyCountHelp: String {
        if lastRefreshKind != nil || lastRefreshLabelID != nil || !lastRefreshQuery.isEmpty {
            return "匹配 \(matchCount) 条，库中共 \(libraryCount) 条"
        }
        return "共 \(libraryCount) 条"
    }

    func loadMore() {
        guard canLoadMore else { return }
        loadMoreInFlight = true
        let generation = listGeneration
        let query = lastRefreshQuery
        let kind = lastRefreshKind
        let labelID = lastRefreshLabelID
        let offset = items.count
        let finish: ([ClipboardItem]) -> Void = { [weak self] page in
            DispatchQueue.main.async {
                guard let self, generation == self.listGeneration else { return }
                self.apply(page, forceSelectFirst: false, append: true)
                self.loadMoreInFlight = false
                if !page.isEmpty {
                    DebugLog.write("续页 +\(page.count) loaded=\(self.items.count)/\(self.matchCount)")
                }
            }
        }
        if query.isEmpty {
            ClipboardStore.shared.fetchAll(
                kind: kind?.rawValue,
                labelID: labelID,
                limit: Self.pageSize,
                offset: offset,
                completion: finish
            )
        } else {
            ClipboardStore.shared.search(
                query,
                kind: kind?.rawValue,
                labelID: labelID,
                limit: Self.pageSize,
                offset: offset,
                completion: finish
            )
        }
    }

    private func refresh(forceSelectFirst: Bool, completion: (() -> Void)? = nil) {
        if refreshInFlight {
            refreshPendingForceSelectFirst =
                (refreshPendingForceSelectFirst ?? false) || forceSelectFirst
            DebugLog.write("refresh coalesce forceSelect=\(forceSelectFirst)")
            completion?()
            return
        }
        refreshInFlight = true
        loadMoreInFlight = false
        listGeneration &+= 1
        let generation = listGeneration
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = filterKind
        let labelID = filterLabelID
        // 同一列表里置顶、打标签或删除时保留已浏览深度；切换查询仍回到轻量首屏。
        let sameContext = query == lastRefreshQuery
            && kind == lastRefreshKind
            && labelID == lastRefreshLabelID
        let fetchLimit = sameContext ? max(Self.pageSize, items.count) : Self.pageSize
        let started = CFAbsoluteTimeGetCurrent()
        let finish: (ClipboardHistoryPage) -> Void = { [weak self] page in
            DispatchQueue.main.async {
                guard let self, generation == self.listGeneration else { return }
                self.libraryCount = page.totalCount
                self.matchCount = page.matchCount
                self.apply(page.items, forceSelectFirst: forceSelectFirst)
                self.lastRefreshAt = CFAbsoluteTimeGetCurrent()
                self.lastRefreshKind = kind
                self.lastRefreshLabelID = labelID
                self.lastRefreshQuery = query
                self.refreshInFlight = false
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                if ms > 16 {
                    DebugLog.write("列表刷新 \(ms)ms count=\(page.items.count)")
                }
                completion?()
                if let pending = self.refreshPendingForceSelectFirst {
                    self.refreshPendingForceSelectFirst = nil
                    self.refresh(forceSelectFirst: pending)
                }
            }
        }
        ClipboardStore.shared.fetchHistoryPage(
            query: query,
            kind: kind?.rawValue,
            labelID: labelID,
            limit: fetchLimit,
            completion: finish
        )
    }

    private func apply(_ newItems: [ClipboardItem], forceSelectFirst: Bool, append: Bool = false) {
        let update = {
            if append {
                let existing = Set(self.items.map(\.id))
                let extra = newItems.filter { !existing.contains($0.id) }
                if !extra.isEmpty {
                    self.items.append(contentsOf: extra)
                }
                return
            }
            let sameContent = self.items.count == newItems.count
                && zip(self.items, newItems).allSatisfy { a, b in
                    a.id == b.id
                        && a.updatedAt == b.updatedAt
                        && a.pinned == b.pinned
                        && a.labelIDs == b.labelIDs
                        && a.hash == b.hash
                }
            if !sameContent {
                self.items = newItems
            } else {
                DebugLog.write("refresh skip same-content")
            }
            if forceSelectFirst {
                let firstID = self.items.first?.id
                if self.selectedID != firstID {
                    self.selectedID = firstID
                }
                // 呼出时 panelWillOpen 已滚过；避免二次 bump 触发列表再布局
                if self.scrollRequestID != firstID {
                    self.requestScroll(to: firstID, animated: !self.suppressListAnimation)
                }
                return
            }
            if let selectedID = self.selectedID, self.items.contains(where: { $0.id == selectedID }) {
                return
            }
            self.selectedID = self.items.first?.id
            self.requestScroll(to: self.selectedID, animated: !self.suppressListAnimation)
        }
        if suppressListAnimation {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else {
            update()
        }
    }

    // MARK: - 键盘导航

    var selectedItem: ClipboardItem? {
        items.first { $0.id == selectedID }
    }

    @discardableResult
    func moveSelection(offset: Int) -> Int64? {
        let currentIndex = items.firstIndex { $0.id == selectedID }
        guard let newIndex = PanelInteractionPolicy.selectionIndex(
            currentIndex: currentIndex,
            itemCount: items.count,
            offset: offset
        ) else {
            return nil
        }
        let newID = items[newIndex].id
        if selectedID != newID {
            selectedID = newID
        }
        if newIndex >= items.count - 4 {
            loadMore()
        }
        return newID
    }

    // MARK: - 粘贴

    func pasteSelected() {
        guard let item = selectedItem else { return }
        paste(item, source: "keyboard", deferFocusHandoff: false)
    }

    /// 鼠标点击粘贴：直接带上条目，并延后焦点交接，避开 ScrollView 点击与窗口切换抢跑。
    func pasteItem(_ item: ClipboardItem) {
        selectedID = item.id
        paste(item, source: "mouse", deferFocusHandoff: true)
    }

    private func paste(_ item: ClipboardItem, source: String, deferFocusHandoff: Bool) {
        let pasteStarted = CFAbsoluteTimeGetCurrent()
        DebugLog.write("\(source)粘贴: \(item.kind.rawValue) \(item.previewLine.prefix(20))")
        if let hash = PasteService.shared.writeToPasteboard(item) {
            ClipboardMonitor.shared.ignore(hash: hash)
        }
        if AppSettings.shared.bumpOnPaste, item.id > 0 {
            ClipboardStore.shared.touch(id: item.id)
        }
        let writeMs = Int((CFAbsoluteTimeGetCurrent() - pasteStarted) * 1000)

        let shouldPaste = AppSettings.shared.autoPasteEnabled && PasteService.hasAccessibilityPermission
        // 粘贴场景跳过淡出动画：面板必须先让出焦点，注入才能落到目标 App。
        requestClose(animated: !shouldPaste)

        if shouldPaste {
            let pid = targetPID
            if deferFocusHandoff {
                // 等鼠标抬起与面板 orderOut 落定后再交还焦点，避免点击路径明显慢于回车
                DispatchQueue.main.async { [weak self] in
                    self?.performPasteHandoff(pid: pid, source: source, writeMilliseconds: writeMs)
                }
            } else {
                performPasteHandoff(pid: pid, source: source, writeMilliseconds: writeMs)
            }
        } else if !PasteService.hasAccessibilityPermission {
            DebugLog.write("粘贴：无辅助功能权限，仅写回剪贴板 write=\(writeMs)ms")
            ToastWindowController.shared.show(
                title: "已写入剪贴板",
                message: "未授权辅助功能，请手动 ⌘V；可在设置中开启",
                systemImage: "exclamationmark.triangle"
            )
        } else {
            DebugLog.write("粘贴：仅写回剪贴板 write=\(writeMs)ms")
        }
    }

    private func performPasteHandoff(pid: pid_t?, source: String, writeMilliseconds: Int) {
        if NSApp.isActive {
            NSApp.deactivate()
        }
        PasteService.activateAndPaste(pid: pid)
        DebugLog.write("粘贴路径 source=\(source) write=\(writeMilliseconds)ms → 注入")
    }

    // MARK: - 基础操作

    func togglePin(_ item: ClipboardItem) {
        ClipboardStore.shared.setPinned(id: item.id, pinned: !item.pinned) { [weak self] in
            DispatchQueue.main.async { self?.refresh(forceSelectFirst: false) }
        }
    }

    func deleteItem(_ item: ClipboardItem) {
        ClipboardStore.shared.delete(id: item.id) { [weak self] in
            DispatchQueue.main.async { self?.refresh(forceSelectFirst: true) }
        }
    }

    func clearAllHistory() {
        ClipboardStore.shared.clear { [weak self] in
            DispatchQueue.main.async { self?.refresh(forceSelectFirst: true) }
        }
    }

    func openSettings() {
        onOpenSettings?()
    }

    // MARK: - 粘贴队列

    /// 面板内 ⌘+点击/⌘+回车：把当前选中项加入队列。
    func enqueueSelected() {
        guard let item = selectedItem else { return }
        let count = pasteQueue.count + 1
        DebugLog.write("面板入队: \(item.kind.rawValue) \(item.previewLine.prefix(20)) count=\(count)")
        pasteQueue.append(item)
        ToastWindowController.shared.showQueue(items: pasteQueue)
    }

    func clearQueue() {
        DebugLog.write("清空队列")
        pasteQueue = []
        ToastWindowController.shared.hideQueue()
    }

    /// 全局快捷键：模拟普通复制（⌘C）后再把新剪贴板内容加入队列。
    func enqueueFromClipboard() {
        guard PasteService.hasAccessibilityPermission else {
            enqueueQueue.async { [weak self] in
                self?.performEnqueueFromClipboard()
            }
            return
        }
        let before = NSPasteboard.general.changeCount
        if let pid = PasteService.frontmostPID() {
            PasteService.injectCommandC(to: pid)
        } else {
            PasteService.injectCommandC()
        }
        waitForPasteboardChange(before: before, deadline: CFAbsoluteTimeGetCurrent() + 0.5)
    }

    /// 高频轮询剪贴板变更：⌘C 通常 10–30ms 内生效，短间隔能显著降低入队的体感延迟。
    private func waitForPasteboardChange(before: Int, deadline: CFAbsoluteTime) {
        if NSPasteboard.general.changeCount != before || CFAbsoluteTimeGetCurrent() >= deadline {
            enqueueQueue.async { [weak self] in
                self?.performEnqueueFromClipboard()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.006) { [weak self] in
            self?.waitForPasteboardChange(before: before, deadline: deadline)
        }
    }

    private nonisolated func performEnqueueFromClipboard() {
        let pasteboard = NSPasteboard.general

        // 图片优先（截图工具可能同时提供图片数据和文件引用）
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let hash = Hashing.sha256Hex(imageData)
            if let existing = ClipboardStore.shared.itemSync(hash: hash) {
                enqueueAppend(existing)
                return
            }
            if let (original, thumb) = saveImageSync(data: imageData, hash: hash) {
                let item = ClipboardItem(
                    id: -1,
                    kind: .image,
                    text: nil,
                    rtfPath: nil,
                    imagePath: thumb,
                    originalImagePath: original,
                    filePaths: [],
                    hash: hash,
                    pinned: false,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                enqueueAppend(item)
            }
            return
        }

        // 文本
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let item = ClipboardItem(
                id: -1,
                kind: text.hasPrefix("http://") || text.hasPrefix("https://") ? .link : .text,
                text: text,
                rtfPath: nil,
                imagePath: nil,
                originalImagePath: nil,
                filePaths: [],
                hash: Hashing.sha256Hex(text),
                pinned: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            enqueueAppend(item)
            return
        }

        // 文件
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            let item = ClipboardItem(
                id: -1,
                kind: .file,
                text: paths.joined(separator: "\n"),
                rtfPath: nil,
                imagePath: nil,
                originalImagePath: nil,
                filePaths: paths,
                hash: Hashing.sha256Hex(filePaths: paths),
                pinned: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            enqueueAppend(item)
            return
        }

        Task { @MainActor in
            ToastWindowController.shared.show(
                title: "无法入队",
                message: "剪贴板为空或不支持的类型",
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private nonisolated func enqueueAppend(_ item: ClipboardItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pasteQueue.append(item)
            DebugLog.write("入队[速]: \(item.kind.rawValue) \(item.previewLine.prefix(20)) count=\(self.pasteQueue.count)")
            ToastWindowController.shared.showQueue(items: self.pasteQueue)
        }
    }

    /// 全局快捷键：从队列取出下一个写回剪贴板并粘贴。
    func dequeueAndPaste() {
        guard !pasteQueue.isEmpty else {
            ToastWindowController.shared.show(
                title: "队列为空",
                message: "先用入队复制（⌥⌘E）收集内容",
                systemImage: "list.number"
            )
            return
        }
        let item = pasteQueue.removeFirst()
        let remaining = pasteQueue.count
        DebugLog.write("出队: \(item.kind.rawValue) \(item.previewLine.prefix(20)) 剩余=\(remaining)")
        // 先记住目标：deactivate 之后 frontmostApplication 会变。
        let target = PasteService.frontmostPID()
        if let hash = PasteService.shared.writeToPasteboard(item) {
            ClipboardMonitor.shared.ignore(hash: hash)
        }
        if AppSettings.shared.bumpOnPaste, item.id > 0 {
            ClipboardStore.shared.touch(id: item.id)
        }
        if PasteService.hasAccessibilityPermission {
            // 出队语义 = 粘贴：有权限就注入，不依赖自动粘贴开关
            if NSApp.isActive {
                NSApp.deactivate()
            }
            PasteService.activateAndPaste(pid: target)
        } else {
            DebugLog.write("出队：无辅助功能权限，仅写回剪贴板")
            ToastWindowController.shared.show(
                title: "已写入剪贴板",
                message: "未授权辅助功能，请手动 ⌘V；可在设置中开启",
                systemImage: "exclamationmark.triangle"
            )
        }
        if pasteQueue.isEmpty {
            ToastWindowController.shared.hideQueue()
        } else {
            ToastWindowController.shared.showQueue(items: pasteQueue)
        }
    }


    // MARK: - 图片落盘

    private nonisolated func saveImageSync(data: Data, hash: String) -> (String, String)? {
        let directory = ClipboardStore.defaultImagesDirectory()
        let originalURL = directory.appendingPathComponent("\(hash).data")
        let thumbURL = directory.appendingPathComponent("\(hash)_thumb.jpg")
        do {
            try data.write(to: originalURL, options: .atomic)
            let thumbData = Self.makeThumbnail(from: data, maxDimension: 512)
            try thumbData?.write(to: thumbURL, options: .atomic)
            return (originalURL.path, thumbURL.path)
        } catch {
            print("保存入队图片失败: \(error)")
            return nil
        }
    }

    private static nonisolated func makeThumbnail(from data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
