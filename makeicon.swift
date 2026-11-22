// 生成 Gloam 的应用图标（暮色海面：落日 + 新月）。用法：swift makeicon.swift 输出.png
import Cocoa

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

// macOS 图标网格：1024 画布内 824 的圆角方形。
let box = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: box, cornerWidth: 186, cornerHeight: 186, transform: nil)
let horizon: CGFloat = 430, cx: CGFloat = 512

// 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape); ctx.setFillColor(rgb(0x141A4A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()

// 天空：自上而下由靛蓝过渡到地平线的暖橙
ctx.drawLinearGradient(gradient([(0, rgb(0x10143C)), (0.30, rgb(0x2B2A72)), (0.58, rgb(0x7A4496)),
                                 (0.80, rgb(0xE0667E)), (1, rgb(0xFFB868))]),
                       start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: horizon), options: [])

// 星星
for (x, y, r, a) in [(250, 800, 6, 0.9), (360, 690, 4, 0.6), (470, 840, 4.5, 0.75), (590, 720, 3.5, 0.5),
                     (820, 640, 5, 0.7), (200, 640, 3.5, 0.45), (640, 850, 3, 0.5)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    ctx.setFillColor(rgb(0xFFFFFF, a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// 新月（带一圈柔光）
let moon = CGPoint(x: 720, y: 742)
ctx.drawRadialGradient(gradient([(0, rgb(0xFFF4D0, 0.28)), (1, rgb(0xFFF4D0, 0))]),
                       startCenter: moon, startRadius: 0, endCenter: moon, endRadius: 150, options: [])
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(rgb(0xFFF6DC))
ctx.fillEllipse(in: CGRect(x: moon.x - 72, y: moon.y - 72, width: 144, height: 144))
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: CGRect(x: moon.x - 72 + 46, y: moon.y - 72 + 32, width: 136, height: 136))
ctx.setBlendMode(.normal)
ctx.endTransparencyLayer()

// 落日：光晕 + 日面
let sun = CGPoint(x: cx, y: horizon)
ctx.drawRadialGradient(gradient([(0, rgb(0xFFE7A8, 0.75)), (0.45, rgb(0xFFB070, 0.32)), (1, rgb(0xFF9A6A, 0))]),
                       startCenter: sun, startRadius: 120, endCenter: sun, endRadius: 400, options: [])
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: sun.x - 178, y: sun.y - 178, width: 356, height: 356)); ctx.clip()
ctx.drawLinearGradient(gradient([(0, rgb(0xFFF7D6)), (0.55, rgb(0xFFD98A)), (1, rgb(0xFFA862))]),
                       start: CGPoint(x: 0, y: sun.y + 178), end: CGPoint(x: 0, y: sun.y - 20), options: [.drawsAfterEndLocation])
ctx.restoreGState()

// 海面
ctx.drawLinearGradient(gradient([(0, rgb(0x2A2468)), (0.35, rgb(0x191A50)), (1, rgb(0x0C0E30))]),
                       start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: box.minY), options: [])
// 地平线上的一抹暖光
ctx.drawLinearGradient(gradient([(0, rgb(0xFFB868, 0.55)), (1, rgb(0xFFB868, 0))]),
                       start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: horizon - 70), options: [])
// 水面倒影：越往下越短、越淡
for (i, (w, a)) in ([(300, 0.95), (236, 0.8), (176, 0.62), (120, 0.45), (72, 0.3)] as [(CGFloat, CGFloat)]).enumerated() {
    let y = horizon - 40 - CGFloat(i) * 52, h: CGFloat = 22
    let bar = CGPath(roundedRect: CGRect(x: cx - w / 2, y: y - h / 2, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
    ctx.addPath(bar); ctx.setFillColor(rgb(0xFFD08A, a)); ctx.fillPath()
}

// 顶部高光描边
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.35)), (0.5, rgb(0xFFFFFF, 0.04)), (1, rgb(0xFFFFFF, 0))]),
                       start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
