// Gen app icon StoryAudio: gradient tím + sách mở + sóng audio trắng
// Chạy: swift gen_icon.swift  → icon-1024.png
import AppKit
import CoreGraphics

let size = 1024
let s = CGFloat(size)

guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("cannot create context")
}

// Nền: rounded-square gradient tím (trên sáng → dưới đậm)
let radius: CGFloat = s * 0.2250
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [CGColor(red: 0.46, green: 0.38, blue: 0.94, alpha: 1),
                               CGColor(red: 0.22, green: 0.16, blue: 0.64, alpha: 1)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// Sóng audio: 7 thanh bo tròn, cao thấp so le (nằm gọn TRÊN mặt sách)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
let heights: [CGFloat] = [0.10, 0.18, 0.27, 0.36, 0.27, 0.18, 0.10]
let barW: CGFloat = s * 0.054
let gap: CGFloat = s * 0.042
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (s - totalW) / 2
let waveMidY = s * 0.70
for h in heights {
    let hh = h * s
    let bar = CGPath(roundedRect: CGRect(x: x, y: waveMidY - hh / 2, width: barW, height: hh),
                     cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    ctx.addPath(bar)
    ctx.fillPath()
    x += barW + gap
}

// Sách mở: 2 lá trang đối xứng, khe gáy rõ ràng
func pagePath(mirror: Bool) -> CGPath {
    let p = CGMutablePath()
    let spineTopY = 0.415, outerTopY = 0.395, bottomOuterY = 0.285, bottomSpineY = 0.305
    let spineX = 0.475, outerX = 0.225, ctrlX = 0.34
    func pt(_ px: Double, _ py: Double) -> CGPoint {
        let rx = mirror ? (1.0 - px) : px
        return CGPoint(x: rx * s, y: py * s)
    }
    p.move(to: pt(spineX, spineTopY))
    p.addQuadCurve(to: pt(outerX, outerTopY), control: pt(ctrlX, 0.44))
    p.addLine(to: pt(outerX, bottomOuterY))
    p.addQuadCurve(to: pt(spineX, bottomSpineY), control: pt(ctrlX, 0.255))
    p.closeSubpath()
    return p
}
ctx.addPath(pagePath(mirror: false))
ctx.addPath(pagePath(mirror: true))
ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon-1024.png"))
print("OK icon-1024.png")
