// Draws the app icon and writes an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
//
// Lit Field in one mark: the still field as the ground, a long ink bar (the
// original) over a short one (the result), closed by the accent dot.

import AppKit
import CoreGraphics
import Foundation

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let scale = size / 1024
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Short contact shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x10141C, 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0xECEEED))
    context.fillPath()
    context.restoreGState()

    // The field: slate-to-amber wash plus the cool and warm lobes.
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()

    let wash = CGGradient(
        colorsSpace: space,
        colors: [color(0xDBE3E7), color(0xE9E6DF), color(0xF7E6D4)] as CFArray,
        locations: [0, 0.46, 1]
    )!
    context.drawLinearGradient(wash, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    func lobe(_ hex: UInt32, x: CGFloat, y: CGFloat, radius: CGFloat) {
        let gradient = CGGradient(colorsSpace: space, colors: [color(hex, 1), color(hex, 0)] as CFArray, locations: [0, 1])!
        let center = CGPoint(x: body.minX + body.width * x, y: body.maxY - body.height * y)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    lobe(0xCFD8D6, x: 0.26, y: 0.84, radius: 520)
    lobe(0xFFCFA8, x: 0.76, y: 0.92, radius: 480)
    lobe(0xFFD9B8, x: 0.90, y: 0.14, radius: 560)
    lobe(0xB9C8D2, x: 0.06, y: 0.10, radius: 600)

    // Lit top edge.
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.85))
    context.setLineWidth(6)
    context.clip(to: CGRect(x: body.minX, y: body.maxY - 200, width: body.width, height: 200))
    context.strokePath()
    context.restoreGState()

    // The mark.
    let barHeight: CGFloat = 108
    let left: CGFloat = 250
    func capsule(x: CGFloat, y: CGFloat, width: CGFloat, fill: CGColor) {
        let rect = CGRect(x: x, y: y, width: width, height: barHeight)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
    }
    capsule(x: left, y: 546, width: 524, fill: color(0x0B0C0E))
    capsule(x: left, y: 370, width: 268, fill: color(0x0B0C0E))
    capsule(x: left + 268 + 44, y: 370, width: barHeight, fill: color(0xFF4726))

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try drawIcon(pixels: points * factor).write(to: output.appendingPathComponent(name))
    }
}
