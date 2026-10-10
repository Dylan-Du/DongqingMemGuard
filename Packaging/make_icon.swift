import AppKit
import CoreGraphics

// 用法: swift make_icon.swift <输入图片> <输出png> [zoom]
// 将任意方图裁切、缩放并套用 macOS 标准圆角方形（squircle）遮罩，输出 1024x1024 带透明通道的 PNG。

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make_icon.swift <input> <output.png> [zoom]")
    exit(1)
}
let inputPath = args[1]
let outputPath = args[2]
let zoom = args.count >= 4 ? (Double(args[3]) ?? 0.74) : 0.74

guard let image = NSImage(contentsOfFile: inputPath),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("无法读取图片: \(inputPath)")
    exit(1)
}

let w = CGFloat(cgImage.width)
let h = CGFloat(cgImage.height)
let side = min(w, h) * CGFloat(zoom)
let cropRect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
guard let cropped = cgImage.cropping(to: cropRect) else {
    print("裁切失败")
    exit(1)
}

let canvas = 1024
let body: CGFloat = 824          // macOS 图标主体的标准占比
let inset = (CGFloat(canvas) - body) / 2

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: canvas,
    height: canvas,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("无法创建绘图上下文")
    exit(1)
}

// 超椭圆（squircle）路径，指数 5 接近苹果的连续圆角
let exponent: CGFloat = 5.0
let radius = body / 2
let path = CGMutablePath()
let steps = 1440
for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * CGFloat.pi
    let ct = cos(t)
    let st = sin(t)
    let x = radius * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1)
    let y = radius * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1)
    let point = CGPoint(x: inset + radius + x, y: inset + radius + y)
    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
}
path.closeSubpath()

let bodyRect = CGRect(x: inset, y: inset, width: body, height: body)

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.draw(cropped, in: bodyRect)
ctx.restoreGState()

// 内侧高光描边，让玻璃质感更接近原生图标
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
ctx.setLineWidth(3)
ctx.addPath(path)
ctx.strokePath()
ctx.restoreGState()

guard let outputImage = ctx.makeImage() else {
    print("渲染失败")
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: outputImage)
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    print("编码 PNG 失败")
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("已生成: \(outputPath)")