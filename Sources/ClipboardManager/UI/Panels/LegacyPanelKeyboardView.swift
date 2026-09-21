import AppKit
import SwiftUI

/// macOS 13 的局部键盘桥接；仅处理所属面板，隐藏、弹窗和其他窗口不拦截。
struct LegacyPanelKeyboardView: NSViewRepresentable {
    let wantsFocus: Bool
    let focusGeneration: UInt
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onKeyDown = onKeyDown
        let needsFocus = wantsFocus && (!view.wantsFocus || view.focusGeneration != focusGeneration)
        view.wantsFocus = wantsFocus
        view.focusGeneration = focusGeneration
        if needsFocus { view.requestFocus() }
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class KeyView: NSView {
        var wantsFocus = false
        var focusGeneration: UInt = 0
        var onKeyDown: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window, window.isKeyWindow, window.isVisible,
                      window.attachedSheet == nil else { return event }
                return self.onKeyDown?(event) == true ? nil : event
            }
            if wantsFocus { requestFocus() }
        }

        func requestFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsFocus, let window = self.window,
                      window.isVisible, window.isKeyWindow, window.attachedSheet == nil else { return }
                window.makeFirstResponder(self)
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopMonitoring() }
    }
}
