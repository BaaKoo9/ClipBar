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

            // 使用 bundle 内 AppIcon，与 Dock / Finder 图标保持一致
            Group {
                if let icon = appIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.06, green: 0.23, blue: 0.27),
                                    Color(red: 0.04, green: 0.10, blue: 0.17)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 16, y: 6)

            Text("ClipBar")
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
                if let url = URL(string: "https://github.com/BaaKoo9/ClipBar") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                    Text("GitHub 支持")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.18, blue: 0.22),
                            Color(red: 0.10, green: 0.12, blue: 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .help("在浏览器中打开 GitHub 仓库")

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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.3"
    }

    private var appIconImage: NSImage? {
        if let icon = NSApp.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        return Bundle.main.image(forResource: "AppIcon")
    }
}
