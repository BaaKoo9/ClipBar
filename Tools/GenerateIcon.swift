import AppKit

// 生成 App 图标：蓝紫渐变圆角底 + 白色剪贴板符号（Liquid Glass 风格）
let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    print("无法获取图形上下文")
    exit(1)
}

// 1. 背景圆角矩形 + 渐变
let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 228, yRadius: 228)
let gradient = NSGradient(
    colors: [
        NSColor(calibratedRed: 0.04, green: 0.51, blue: 0.91, alpha: 1.0),
        NSColor(calibratedRed: 0.37, green: 0.34, blue: 0.89, alpha: 1.0)
    ]
)
gradient?.draw(in: background, angle: -65)

// 顶部高光（玻璃质感）
let highlight = NSBezierPath(roundedRect: NSRect(x: 90, y: 700, width: 844, height: 234), xRadius: 160, yRadius: 160)
NSColor(calibratedWhite: 1.0, alpha: 0.16).setFill()
highlight.fill()

ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)

// 2. 剪贴板主体（白色圆角矩形板）
let boardRect = NSRect(x: 272, y: 250, width: 480, height: 520)
let board = NSBezierPath(roundedRect: boardRect, xRadius: 56, yRadius: 56)
NSColor.white.setFill()
board.fill()

// 3. 顶部夹子（矩形缺口 + 两侧圆角）
let clipRect = NSRect(x: 386, y: 742, width: 252, height: 92)
let clip = NSBezierPath(roundedRect: clipRect, xRadius: 40, yRadius: 40)
NSColor(calibratedRed: 0.10, green: 0.56, blue: 0.95, alpha: 1.0).setFill()
clip.fill()

// 夹子上方小拱形
let archRect = NSRect(x: 438, y: 812, width: 148, height: 58)
let arch = NSBezierPath(roundedRect: archRect, xRadius: 29, yRadius: 29)
gradient?.draw(in: arch, angle: 0)

// 4. 板内文字行（蓝色圆角条，模拟剪贴板内容）
ctx.setShadow(offset: .zero, blur: 0, color: nil)
let line1 = NSBezierPath(roundedRect: NSRect(x: 330, y: 600, width: 364, height: 54), xRadius: 27, yRadius: 27)
NSColor(calibratedRed: 0.10, green: 0.56, blue: 0.95, alpha: 1.0).setFill()
line1.fill()

let line2 = NSBezierPath(roundedRect: NSRect(x: 330, y: 510, width: 300, height: 54), xRadius: 27, yRadius: 27)
NSColor(calibratedRed: 0.10, green: 0.56, blue: 0.95, alpha: 0.55).setFill()
line2.fill()

let line3 = NSBezierPath(roundedRect: NSRect(x: 330, y: 420, width: 240, height: 54), xRadius: 27, yRadius: 27)
NSColor(calibratedRed: 0.10, green: 0.56, blue: 0.95, alpha: 0.35).setFill()
line3.fill()

image.unlockFocus()

// 输出各尺寸
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    print("图标编码失败")
    exit(1)
}

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.iconset")

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, pixelSize) in sizes {
    guard let resized = rep.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
        print("尺寸 \(pixelSize) 编码失败")
        continue
    }
    let scaled = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    scaled.unlockFocus()
    guard let t2 = scaled.tiffRepresentation,
          let r2 = NSBitmapImageRep(data: t2),
          let png2 = r2.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
        continue
    }
    try? png2.write(to: outputDir.appendingPathComponent(name))
}

print("图标 PNG 已生成到 Resources/AppIcon.iconset")
