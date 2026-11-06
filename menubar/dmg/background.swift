// The DMG window's background, in the logo's colors: ink on paper, the "koe" wordmark at the top, a thin arrow
// from Koe to Applications and a line saying what to do. dmg.sh runs it:
//     swift menubar/dmg/background.swift WORDMARK.png OUT_DIR
// and gets OUT_DIR/background.png (640×400) and background@2x.png (1280×800), which it joins into one TIFF.
// The icon positions here and in dmg.sh must match (Koe at x 170, Applications at x 470, both at y 205).
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let wordmark = NSImage(contentsOfFile: args[1]) else {
    print("usage: swift background.swift WORDMARK.png OUT_DIR")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])

let width = 640.0, height = 400.0
let paper = NSColor(srgbRed: 0xEF / 255.0, green: 0xEB / 255.0, blue: 0xE3 / 255.0, alpha: 1)
let ink = NSColor(srgbRed: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1C / 255.0, alpha: 1)

func draw(scale: Double) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Finder's coordinates go from the top, AppKit's from the bottom
    func y(_ top: Double) -> Double { height - top }

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // the wordmark, centered at the top
    let markHeight = 46.0
    let markWidth = markHeight * wordmark.size.width / wordmark.size.height
    wordmark.draw(in: NSRect(x: (width - markWidth) / 2, y: y(40 + markHeight), width: markWidth, height: markHeight))

    // the arrow between the icons: a thin line with a slight wave, like the ring's water
    let arrow = NSBezierPath()
    let from = NSPoint(x: 262, y: y(205)), to = NSPoint(x: 378, y: y(205))
    arrow.move(to: from)
    arrow.curve(to: to, controlPoint1: NSPoint(x: 300, y: y(197)), controlPoint2: NSPoint(x: 340, y: y(213)))
    arrow.move(to: NSPoint(x: to.x - 11, y: to.y + 7))
    arrow.line(to: to)
    arrow.line(to: NSPoint(x: to.x - 11, y: to.y - 7))
    arrow.lineWidth = 1.6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    ink.withAlphaComponent(0.55).setStroke()
    arrow.stroke()

    // what to do
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "Drag Koe into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .light),
        .foregroundColor: ink.withAlphaComponent(0.6),
        .paragraphStyle: style,
    ])
    text.draw(in: NSRect(x: 0, y: y(336), width: width, height: 22))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    guard let png = draw(scale: scale) else { print("couldn't draw \(name)"); exit(1) }
    try png.write(to: outDir.appendingPathComponent(name))
}
