// Generates the DeskBar app icon (1024×1024 PNG) with CoreGraphics.
// Usage: swift make_icon.swift <output.png>
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let size = 1024
let S = CGFloat(size)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

func rrect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// --- Background squircle with a purple→blue diagonal gradient ---
let margin: CGFloat = 78
let bg = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
ctx.saveGState()
ctx.addPath(rrect(bg, 205))
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [color(0.55, 0.34, 1.0), color(0.18, 0.42, 1.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: margin, y: S - margin),
                       end: CGPoint(x: S - margin, y: margin), options: [])
ctx.restoreGState()

let white = color(1, 1, 1)

// --- Desk (tabletop + two legs) ---
ctx.setFillColor(white)
ctx.addPath(rrect(CGRect(x: 272, y: 508, width: 480, height: 48), 16)); ctx.fillPath()   // tabletop
ctx.addPath(rrect(CGRect(x: 314, y: 446, width: 40, height: 66), 12)); ctx.fillPath()     // left leg
ctx.addPath(rrect(CGRect(x: 670, y: 446, width: 40, height: 66), 12)); ctx.fillPath()     // right leg

// --- Up / down chevrons (height adjust) ---
ctx.setStrokeColor(white)
ctx.setLineWidth(60)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
// up chevron ^ above the tabletop
ctx.move(to: CGPoint(x: 396, y: 640))
ctx.addLine(to: CGPoint(x: 512, y: 726))
ctx.addLine(to: CGPoint(x: 628, y: 640))
ctx.strokePath()
// down chevron v below the legs
ctx.move(to: CGPoint(x: 396, y: 408))
ctx.addLine(to: CGPoint(x: 512, y: 322))
ctx.addLine(to: CGPoint(x: 628, y: 408))
ctx.strokePath()

// --- Export PNG ---
guard CommandLine.arguments.count > 1 else { fatalError("pass output path") }
let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("export failed") }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outURL.path)")
