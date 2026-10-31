// Génère l'icône de VidSniper : fond sombre façon Obsidian, coins de sélection de zone,
// viseur violet et point d'enregistrement.
// Usage : swiftc make-icon.swift -o make-icon && ./make-icon VidSniper/Resources/Assets.xcassets/AppIcon.appiconset
// Écrit toutes les tailles attendues par macOS (16 à 512 pt, en 1x et 2x) dans le dossier donné.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let outputFolder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Gabarit des icônes macOS : un carré arrondi de 824 px centré, avec une ombre portée.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, alpha: 0.45))
context.addPath(tilePath)
context.setFillColor(color(0x1E1E1E))
context.fillPath()
context.restoreGState()

// Fond : dégradé sombre vertical.
context.saveGState()
context.addPath(tilePath)
context.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [color(0x2D2B33), color(0x18171B)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
context.restoreGState()

// Liseré discret.
context.addPath(tilePath)
context.setStrokeColor(color(0xFFFFFF, alpha: 0.08))
context.setLineWidth(3)
context.strokePath()

let center = CGPoint(x: size / 2, y: size / 2)
let accent = color(0x8A5CF5)
let light = color(0xDADADA)

// Coins d'une sélection de zone.
let frame = tile.insetBy(dx: 120, dy: 120)
let bracket: CGFloat = 120
context.setStrokeColor(light)
context.setLineWidth(28)
context.setLineCap(.round)
context.setLineJoin(.round)
for (corner, dx, dy) in [
    (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0),
    (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
    (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0),
    (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
] {
    context.move(to: CGPoint(x: corner.x, y: corner.y + dy * bracket))
    context.addLine(to: corner)
    context.addLine(to: CGPoint(x: corner.x + dx * bracket, y: corner.y))
    context.strokePath()
}

// Viseur : anneau et réticule violets, avec un espace autour du centre.
let ringRadius: CGFloat = 165
context.setStrokeColor(accent)
context.setLineWidth(24)
context.strokeEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))

context.setLineWidth(18)
let inner: CGFloat = 92
let outer: CGFloat = 235
for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
    context.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
    context.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
    context.strokePath()
}

// Point d'enregistrement, avec un léger halo.
let dotRadius: CGFloat = 52
context.saveGState()
context.setShadow(offset: .zero, blur: 40, color: color(0xFB464C, alpha: 0.8))
context.setFillColor(color(0xFB464C))
context.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
context.restoreGState()

let image = context.makeImage()!

/// Réduit l'icône 1024 px à `pixels` px et l'écrit en PNG.
func write(pixels: Int, to url: URL) throws {
    let scaled = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let representation = NSBitmapImageRep(cgImage: scaled.makeImage()!)
    try representation.representation(using: .png, properties: [:])!.write(to: url)
}

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(pixels: points * scale, to: outputFolder.appending(path: name))
        entries.append(
            #"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#
        )
    }
}
let contents = "{\n  \"images\" : [\n\(entries.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: outputFolder.appending(path: "Contents.json"), atomically: false, encoding: .utf8)
print("Icônes écrites dans \(outputFolder.path)")
