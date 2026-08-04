import AppKit

// 生成 App 图标：深墨底 + 薄荷青错位卡片堆。
// 刻意避开"剪贴板 + 夹子"造型（Paste / Maccy / CleanClip / Pastebot 都在用），
// 改以本应用的差异化功能——粘贴队列——作为视觉主体：三张错位堆叠的卡片。

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let inkTop = color(0x101A2B)
let inkBottom = color(0x0A3A46)
let mint = color(0x4ADE80)
let cyan = color(0x22D3EE)
let deepInk = color(0x0A1220)

/// 按 1024 基准比例绘制，各尺寸独立渲染，小图标才不会糊。
func drawIcon(side: CGFloat) {
    let u = side / 1024

    // 背景：深墨到暗青的对角渐变
    let background = NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
        xRadius: 228 * u,
        yRadius: 228 * u
    )
    NSGradient(colors: [inkTop, inkBottom])?.draw(in: background, angle: -70)

    // 卡片堆背后的青色辉光，制造纵深
    background.setClip()
    if let glow = NSGradient(colors: [cyan.withAlphaComponent(0.30), cyan.withAlphaComponent(0)]) {
        let center = NSPoint(x: 470 * u, y: 470 * u)
        glow.draw(
            fromCenter: center,
            radius: 0,
            toCenter: center,
            radius: 430 * u,
            options: []
        )
    }

    let cardSize = NSSize(width: 470 * u, height: 392 * u)
    let radius = 58 * u

    func card(x: CGFloat, y: CGFloat) -> NSBezierPath {
        NSBezierPath(
            roundedRect: NSRect(x: x * u, y: y * u, width: cardSize.width, height: cardSize.height),
            xRadius: radius,
            yRadius: radius
        )
    }

    // 后两张：队列中等待的条目，越靠后越淡
    color(0xC8F5F0, alpha: 0.20).setFill()
    card(x: 348, y: 388).fill()

    color(0xD8FAF4, alpha: 0.42).setFill()
    card(x: 295, y: 322).fill()

    // 最前一张：下一个要粘贴的条目
    let front = card(x: 242, y: 256)
    if let context = NSGraphicsContext.current?.cgContext {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -18 * u),
            blur: 44 * u,
            color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor
        )
        color(0xFFFFFF).setFill()
        front.fill()
        context.restoreGState()
    }
    NSGradient(colors: [mint, cyan])?.draw(in: front, angle: -55)

    // 前卡上的内容行，暗示"文本条目"
    let lines: [(CGFloat, CGFloat, CGFloat)] = [
        (300, 524, 322),
        (300, 452, 258),
        (300, 380, 176)
    ]
    for (index, line) in lines.enumerated() {
        let (x, y, width) = line
        let bar = NSBezierPath(
            roundedRect: NSRect(x: x * u, y: y * u, width: width * u, height: 42 * u),
            xRadius: 21 * u,
            yRadius: 21 * u
        )
        deepInk.withAlphaComponent(0.85 - CGFloat(index) * 0.24).setFill()
        bar.fill()
    }
}

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, pixelSize) in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        print("尺寸 \(pixelSize) 创建位图失败")
        continue
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(side: CGFloat(pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
        print("尺寸 \(pixelSize) 编码失败")
        continue
    }
    try? png.write(to: outputDir.appendingPathComponent(name))
}

print("图标 PNG 已生成到 Resources/AppIcon.iconset")
