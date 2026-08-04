import AppKit
import SwiftUI

/// 关于窗口：版本信息与项目简介。
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            // 标题栏
            HStack {
                Spacer()
                Button {
                    NSApp.keyWindow?.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.04, green: 0.51, blue: 0.91), Color(red: 0.37, green: 0.34, blue: 0.89)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                    .shadow(color: Color.black.opacity(0.2), radius: 16, y: 6)
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)
            }

            Text("Clipboard Manager")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.5)

            Text("Version \(versionString)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                Text("本地优先、高性能、简约的 macOS 剪贴板管理器")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Label("键盘流：⌥⌘V 呼出 · ⌥⌘E 入队 · ⌥⌘D 出队", systemImage: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Label("零网络权限，所有数据仅存本机", systemImage: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)

            Spacer()

            Button {
                if let url = URL(string: "https://github.com/BaaKoo9/clipboard-manager") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                    Text("github.com/BaaKoo9/clipboard-manager")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.link)

            Text("Copyright © 2026")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 20)
        .frame(width: 420, height: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
    }
}
