import AppKit
import SwiftUI

@MainActor
final class UpdateProgressWindowController {
    static let shared = UpdateProgressWindowController()

    private var window: PanelWindow?

    private init() {}

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: UpdateProgressView(progress: UpdateProgressModel.shared)
        )
        let panel = PanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 142),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "ClipBar 更新"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentViewController = hosting
        panel.center()
        window = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct UpdateProgressView: View {
    @ObservedObject var progress: UpdateProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: phaseIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(phaseColor)
                    .frame(width: 24)
                Text(progress.statusText.isEmpty ? "正在准备更新…" : progress.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            if case .downloading = progress.phase {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text("下载完成后将自动替换应用并重新启动")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 380, height: 142, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private var phaseIcon: String {
        switch progress.phase {
        case .installing: return "arrow.triangle.2.circlepath.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.down.circle.fill"
        }
    }

    private var phaseColor: Color {
        if case .failed = progress.phase { return .red }
        return .accentColor
    }
}
