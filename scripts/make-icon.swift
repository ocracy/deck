#!/usr/bin/env swift
import AppKit

// Deck için AppIcon.iconset üretir.
// Stil: koyu lacivert→mor gradyanlı yuvarlak kare, üzerinde 2×2 "masaüstü ikonları"
// grid'i — Deck'in proje kokpiti fikrine gönderme.

let outIconset = "AppIcon.iconset"
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

let fm = FileManager.default
try? fm.removeItem(atPath: outIconset)
try? fm.createDirectory(atPath: outIconset, withIntermediateDirectories: true)

func draw(size: Int, to path: String) {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // macOS ikon ızgarası: kenarlardan ~%10 boşluk
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 0.29, green: 0.20, blue: 0.55, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: 60)

    // Hafif üst parlaklık
    let glossRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    let gloss = NSBezierPath(roundedRect: glossRect, xRadius: radius, yRadius: radius)
    NSColor.white.withAlphaComponent(0.05).setFill()
    gloss.fill()

    // 2×2 ikon grid'i: terminal, claude yıldızı, play, globe hissi veren basit glifler
    let cell = rect.width * 0.30
    let gap = rect.width * 0.10
    let gridW = cell * 2 + gap
    let x0 = rect.midX - gridW / 2
    let y0 = rect.midY - gridW / 2

    func tile(_ col: Int, _ row: Int, _ color: NSColor) -> NSRect {
        let r = NSRect(x: x0 + CGFloat(col) * (cell + gap),
                       y: y0 + CGFloat(row) * (cell + gap),
                       width: cell, height: cell)
        let p = NSBezierPath(roundedRect: r, xRadius: cell * 0.24, yRadius: cell * 0.24)
        color.setFill()
        p.fill()
        return r
    }

    // Sol üst: terminal (yeşil) — ">_"
    let tTerm = tile(0, 1, NSColor(calibratedRed: 0.15, green: 0.72, blue: 0.45, alpha: 1))
    let line = NSBezierPath()
    line.lineWidth = max(1, cell * 0.11)
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    line.move(to: NSPoint(x: tTerm.minX + cell * 0.22, y: tTerm.maxY - cell * 0.30))
    line.line(to: NSPoint(x: tTerm.minX + cell * 0.42, y: tTerm.midY + cell * 0.02))
    line.line(to: NSPoint(x: tTerm.minX + cell * 0.22, y: tTerm.minY + cell * 0.34))
    line.move(to: NSPoint(x: tTerm.midX + cell * 0.02, y: tTerm.minY + cell * 0.26))
    line.line(to: NSPoint(x: tTerm.maxX - cell * 0.20, y: tTerm.minY + cell * 0.26))
    NSColor.white.setStroke()
    line.stroke()

    // Sağ üst: claude (turuncu) — dört kollu yıldız
    let tCl = tile(1, 1, NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
    let star = NSBezierPath()
    let cx = tCl.midX, cy = tCl.midY
    let rOut = cell * 0.32, rIn = cell * 0.10
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 8
        let r = i % 2 == 0 ? rOut : rIn
        let pt = NSPoint(x: cx + cos(angle) * r, y: cy + sin(angle) * r)
        if i == 0 { star.move(to: pt) } else { star.line(to: pt) }
    }
    star.close()
    NSColor.white.setFill()
    star.fill()

    // Sol alt: play (mavi) — üçgen
    let tPlay = tile(0, 0, NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 1))
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: tPlay.minX + cell * 0.32, y: tPlay.minY + cell * 0.24))
    tri.line(to: NSPoint(x: tPlay.minX + cell * 0.32, y: tPlay.maxY - cell * 0.24))
    tri.line(to: NSPoint(x: tPlay.maxX - cell * 0.24, y: tPlay.midY))
    tri.close()
    NSColor.white.setFill()
    tri.fill()

    // Sağ alt: web (camgöbeği) — daire + meridyen
    let tWeb = tile(1, 0, NSColor(calibratedRed: 0.16, green: 0.65, blue: 0.78, alpha: 1))
    let globe = NSBezierPath()
    globe.lineWidth = max(1, cell * 0.09)
    let gr = cell * 0.28
    globe.appendOval(in: NSRect(x: tWeb.midX - gr, y: tWeb.midY - gr, width: gr * 2, height: gr * 2))
    globe.appendOval(in: NSRect(x: tWeb.midX - gr * 0.45, y: tWeb.midY - gr, width: gr * 0.9, height: gr * 2))
    globe.move(to: NSPoint(x: tWeb.midX - gr, y: tWeb.midY))
    globe.line(to: NSPoint(x: tWeb.midX + gr, y: tWeb.midY))
    NSColor.white.setStroke()
    globe.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG üretilemedi: \(path)")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

for (size, name) in sizes {
    draw(size: size, to: "\(outIconset)/\(name)")
}
print("✓ \(outIconset) üretildi")
