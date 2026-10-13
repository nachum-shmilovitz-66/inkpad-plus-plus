// Draws the MacPad++ app icon at every size macOS needs and writes the asset catalog entry.
// An original design (not Notepad++'s chameleon, which is its brand): a page of code lines in
// Notepad++'s default-theme colours on a slate tile, with a "++" badge.
//
// Usage: swift scripts/make-icon.swift            (writes MacPad/Resources/Assets.xcassets/AppIcon.appiconset)
//        swift scripts/make-icon.swift <out.png>   (writes only a 1024 px preview)
import AppKit

// MARK: - Drawing (in a 1024 × 1024 design space, origin bottom-left)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ ctx: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor, _ rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    ctx.restoreGState()
}

/// `small` drops detail for 16/32 px so the shapes stay legible.
func drawIcon(_ ctx: CGContext, small: Bool) {
    // Tile: Apple's macOS icon grid — 824 pt body centred in 1024, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x1E2533))
    ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, tilePath, rgb(0x3A4560), rgb(0x161B27), tile)

    // Page, tilted slightly, with a shadow.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 520)
    ctx.rotate(by: -0.06)
    let page = CGRect(x: -270, y: -330, width: 540, height: 660)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.45))
    ctx.addPath(roundedRect(page, 34))
    ctx.setFillColor(rgb(0xFBFBF8))
    ctx.fillPath()
    ctx.restoreGState()

    // Line-number gutter, as in Notepad++.
    let gutter = CGRect(x: page.minX, y: page.minY, width: small ? 0 : 74, height: page.height)
    if !small {
        ctx.saveGState()
        ctx.addPath(roundedRect(page, 34))
        ctx.clip()
        ctx.setFillColor(rgb(0xE4E4E4))
        ctx.fill(gutter)
        ctx.restoreGState()
    }

    // Code lines: (indent level, [(width, colour)]) — Notepad++ default theme colours.
    let blue = rgb(0x0000FF), purple = rgb(0x8000FF), green = rgb(0x008000)
    let orange = rgb(0xFF8000), black = rgb(0x30343C), grey = rgb(0x808080)
    typealias Line = (indent: Int, segments: [(CGFloat, CGColor)])
    let smallLines: [Line] = [
        (0, [(120, blue), (200, black)]),
        (1, [(110, purple), (150, orange)]),
        (1, [(240, green)]),
    ]
    var fullLines: [Line] = []
    fullLines.append((0, [(70, green), (210, green)]))
    fullLines.append((0, [(96, blue), (150, black), (30, black)]))
    fullLines.append((1, [(72, purple), (110, black), (60, orange)]))
    fullLines.append((1, [(50, blue), (90, black), (40, black)]))
    fullLines.append((2, [(80, blue), (130, grey)]))
    fullLines.append((1, [(30, black)]))
    fullLines.append((1, [(80, blue), (60, orange)]))
    fullLines.append((0, [(30, black)]))
    let lines = small ? smallLines : fullLines
    let lineHeight: CGFloat = small ? 150 : 66
    let barHeight: CGFloat = small ? 64 : 26
    let left = gutter.maxX + (small ? 60 : 34)
    var y = page.maxY - (small ? 150 : 84)
    for (indent, segments) in lines {
        var x = left + CGFloat(indent) * (small ? 50 : 40)
        for (width, colour) in segments {
            ctx.addPath(roundedRect(CGRect(x: x, y: y, width: width, height: barHeight), barHeight / 2))
            ctx.setFillColor(colour)
            ctx.fillPath()
            x += width + (small ? 24 : 16)
        }
        if !small {  // line-number tick in the gutter
            ctx.addPath(roundedRect(CGRect(x: gutter.minX + 24, y: y + 4, width: 28, height: barHeight - 8), 6))
            ctx.setFillColor(rgb(0xA8A8A8))
            ctx.fillPath()
        }
        y -= lineHeight
    }
    ctx.restoreGState()

    // "++" badge, bottom right, overlapping the page.
    let badge = CGRect(x: 560, y: 150, width: 330, height: 330)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x000000, 0.4))
    ctx.addEllipse(in: badge)
    ctx.setFillColor(rgb(0x2FA84F))
    ctx.fillPath()
    ctx.restoreGState()
    let badgePath = CGPath(ellipseIn: badge, transform: nil)
    fillGradient(ctx, badgePath, rgb(0x52D273), rgb(0x23913F), badge)
    ctx.addPath(badgePath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.9))
    ctx.setLineWidth(small ? 22 : 14)
    ctx.strokePath()

    // Two plus signs drawn as shapes (crisp at every size, no font dependency).
    let arm: CGFloat = small ? 50 : 44, thick: CGFloat = small ? 34 : 30
    for cx in [badge.midX - 66, badge.midX + 66] {
        let cy = badge.midY
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.addPath(roundedRect(CGRect(x: cx - arm, y: cy - thick / 2, width: arm * 2, height: thick), thick / 2))
        ctx.addPath(roundedRect(CGRect(x: cx - thick / 2, y: cy - arm, width: thick, height: arm * 2), thick / 2))
        ctx.fillPath()
    }
}

func renderPNG(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx, small: pixels <= 32)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Output

let args = CommandLine.arguments
if args.count > 1 {
    try! renderPNG(pixels: 1024).write(to: URL(fileURLWithPath: args[1]))
    exit(0)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("MacPad/Resources/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! renderPNG(pixels: points * scale).write(to: set.appendingPathComponent(file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
let catalog: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon images to \(set.path)")
