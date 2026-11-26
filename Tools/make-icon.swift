// Draws the app icon: the state-of-charge gauge of the dashboard with a bolt.
// Usage: swift Tools/make-icon.swift EmusLink/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Linear blend between two colours given as 0xRRGGBB.
func blend(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func channel(_ shift: UInt32) -> CGFloat {
        let x = CGFloat((a >> shift) & 0xFF), y = CGFloat((b >> shift) & 0xFF)
        return (x + (y - x) * t) / 255
    }
    return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha channel: an app icon has to be opaque.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Background: almost black with a hint of green, like the dashboard.
let background = CGGradient(colorsSpace: space, colors: [rgb(0x1B2A22), rgb(0x050806)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

let center = CGPoint(x: 512, y: 500)
let radius: CGFloat = 318
let width: CGFloat = 88
let startAngle: CGFloat = 225          // lower left, in degrees (y axis points up)
let sweep: CGFloat = 270               // clockwise over the top to the lower right
let charge: CGFloat = 0.78             // how far the gauge is filled

func radians(_ fraction: CGFloat) -> CGFloat { (startAngle - sweep * fraction) * .pi / 180 }

func arc(from: CGFloat, to: CGFloat, color: CGColor, cap: CGLineCap) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.addArc(center: center, radius: radius, startAngle: radians(from), endAngle: radians(to), clockwise: true)
    ctx.strokePath()
}

// Track.
arc(from: 0, to: 1, color: rgb(0xFFFFFF, 0.12), cap: .round)

// Filled part: yellow to green, drawn as many short pieces.
let low: UInt32 = 0xFFD60A, high: UInt32 = 0x30D158
func color(at fraction: CGFloat) -> CGColor { blend(low, high, min(1, fraction / 0.45)) }
arc(from: 0, to: 0.001, color: color(at: 0), cap: .round)
arc(from: charge - 0.001, to: charge, color: color(at: charge), cap: .round)
let steps = 400
for i in 0..<steps {
    let a = charge * CGFloat(i) / CGFloat(steps)
    let b = charge * (CGFloat(i) + 1.5) / CGFloat(steps)   // slight overlap hides the seams
    arc(from: a, to: min(b, charge), color: color(at: a), cap: .butt)
}

// Bolt.
let bolt: [(CGFloat, CGFloat)] = [(44, 196), (-128, -28), (-14, -28), (-52, -196), (128, 36), (14, 36)]
ctx.beginPath()
for (i, p) in bolt.enumerated() {
    let point = CGPoint(x: center.x + p.0, y: center.y + p.1)
    if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
}
ctx.closePath()
ctx.setFillColor(rgb(0xFFFFFF))
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(22)
ctx.setLineJoin(.round)
ctx.drawPath(using: .fillStroke)

let image = ctx.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output)") }
print("wrote \(output)")
