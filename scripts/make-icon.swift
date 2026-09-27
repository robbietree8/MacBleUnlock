// 生成 MacBleUnlock 的 AppIcon.icns。纯 CoreGraphics 画出来，仓库里不存二进制素材。
//
// 用法：swift scripts/make-icon.swift Resources/AppIcon.icns
//
// 设计：深蓝渐变圆角方块 + 白色挂锁 + 两侧信号弧（「按距离」= 信号强度）。
// 每个尺寸都用矢量重画而不是缩图，16pt 下信号弧自然淡出、只剩挂锁轮廓。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let design: CGFloat = 1024

// macOS 图标模板：1024 canvas 里的圆角方块是 824×824 居中（四边各留 100），圆角半径 185.4。
let inset: CGFloat = 100
let side: CGFloat = design - inset * 2
let radius: CGFloat = 185.4

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let darkNavy = srgb(0x0B, 0x14, 0x2B)

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// 绘制整个图标，坐标系是 1024×1024（原点左下）。
func drawIcon(in ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let squircle = CGPath(
        roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    // 软阴影，让图标在浅色背景上也立得住。
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 46, color: srgb(0, 0, 0, 0.38))
    ctx.addPath(squircle)
    ctx.setFillColor(darkNavy)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // 背景：底部近黑，顶部亮蓝。
    ctx.drawLinearGradient(
        gradient([srgb(0x3D, 0x7B, 0xEE), srgb(0x1B, 0x3A, 0x8C), srgb(0x0B, 0x14, 0x2B)], [0, 0.52, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )
    // 顶部高光。
    ctx.drawRadialGradient(
        gradient([srgb(255, 255, 255, 0.20), srgb(255, 255, 255, 0)], [0, 1]),
        startCenter: CGPoint(x: 512, y: 880), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 880), endRadius: 640, options: []
    )

    // 两侧信号弧：越远越淡。
    ctx.setLineCap(.round)
    for (i, r) in [240.0, 310.0, 380.0].enumerated() {
        let alpha = 0.44 - CGFloat(i) * 0.15
        ctx.setStrokeColor(srgb(0x8C, 0xBE, 0xFF, alpha))
        ctx.setLineWidth(22)
        ctx.addArc(center: CGPoint(x: 512, y: 512), radius: r,
                   startAngle: 138 * .pi / 180, endAngle: 222 * .pi / 180, clockwise: false)
        ctx.strokePath()
        ctx.addArc(center: CGPoint(x: 512, y: 512), radius: r,
                   startAngle: -42 * .pi / 180, endAngle: 42 * .pi / 180, clockwise: false)
        ctx.strokePath()
    }

    // 锁梁：圆心压在锁体上沿，半圆正好落在锁体上。
    ctx.setStrokeColor(srgb(0xF2, 0xF7, 0xFF))
    ctx.setLineWidth(46)
    ctx.addArc(center: CGPoint(x: 512, y: 550), radius: 100,
               startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()

    // 锁体。
    let body = CGPath(
        roundedRect: CGRect(x: 352, y: 300, width: 320, height: 250),
        cornerWidth: 52, cornerHeight: 52, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([srgb(255, 255, 255), srgb(0xD3, 0xE1, 0xF7)], [0, 1]),
        start: CGPoint(x: 512, y: 550), end: CGPoint(x: 512, y: 300), options: []
    )
    ctx.restoreGState()

    // 钥匙孔：圆 + 向下收窄的槽。
    ctx.setFillColor(darkNavy)
    ctx.fillEllipse(in: CGRect(x: 486, y: 410, width: 52, height: 52))
    let slot = CGMutablePath()
    slot.move(to: CGPoint(x: 499, y: 424))
    slot.addLine(to: CGPoint(x: 525, y: 424))
    slot.addLine(to: CGPoint(x: 517, y: 380))
    slot.addLine(to: CGPoint(x: 507, y: 380))
    slot.closeSubpath()
    ctx.addPath(slot)
    ctx.fillPath()

    ctx.restoreGState()
}

func writeIcon(pixels: Int, to url: URL) {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(pixels) / design, y: CGFloat(pixels) / design)
    drawIcon(in: ctx)

    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("写不出 PNG：\(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let fm = FileManager.default
// MBU_ICONSET_DIR：把中间产物 iconset 留在指定目录里，方便逐个尺寸肉眼看。
let keepDir = ProcessInfo.processInfo.environment["MBU_ICONSET_DIR"]
let iconset = keepDir.map { URL(fileURLWithPath: $0).appendingPathComponent("AppIcon.iconset") }
    ?? URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MacBleUnlock-\(UUID().uuidString).iconset")
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { if keepDir == nil { try? fm.removeItem(at: iconset) } }

// iconutil 要的 10 个尺寸，一个不能少（16@2x 和 32 像素相同但文件名不同，得各写一份）。
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let url = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    writeIcon(pixels: points * scale, to: url)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
print("写出 \(output.path)")
