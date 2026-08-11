import SwiftUI

/// ClipBar 品牌色，与 App 图标（mint / cyan / ink）对齐。
enum BrandTheme {
    static let mint = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
    /// 设置侧栏 / 按钮用的浅绿（比主 accent 浅一档，又不过于发白）。
    static let mintSoft = Color(red: 0xB0 / 255, green: 0xF0 / 255, blue: 0xC8 / 255)
    /// 搜索命中：暖琥珀底 + 深字，暗底上比薄荷绿更易辨认。
    static let searchHit = Color(red: 0xF5 / 255, green: 0x9E / 255, blue: 0x0B / 255)
    static let cyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    static let inkTop = Color(red: 0x10 / 255, green: 0x1A / 255, blue: 0x2B / 255)
    static let inkBottom = Color(red: 0x0A / 255, green: 0x3A / 255, blue: 0x46 / 255)

    static let accent = mint
    /// 设置里选中底 / 主按钮填充。
    static let accentSoft = mintSoft

    static let panelStroke = Color.white.opacity(0.22)
    /// 选中描边：更实、更亮，暗底上更易辨认。
    static let selectedStroke = Color(red: 0x6E / 255, green: 0xF7 / 255, blue: 0xA0 / 255)

    static let cardFill = Color.primary.opacity(0.08)
    static let cardFillHover = Color.primary.opacity(0.12)
    static let cardFillSelected = Color.black.opacity(0.16)

    /// 序号默认色：略偏青的亮薄荷，未选中也够醒目。
    static let index = Color(red: 0x5E / 255, green: 0xF0 / 255, blue: 0xC0 / 255)

    static var panelWash: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.14),
                Color.white.opacity(0.04),
                mint.opacity(0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
