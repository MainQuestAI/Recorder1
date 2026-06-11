import AppKit

// Recorder app icon — rendered headlessly with pure AppKit / Core Graphics
// (no design tools, no external assets). Run via ./make-icon.sh, which executes
// this to produce Recorder-1024.png and then packs every size into Recorder.icns.
//
// Design: a bold red "record" ring around a white microphone on a deep near-black
// squircle — instantly reads as "record audio" and stays legible down to menu-bar
// size. To try a different look, replace this file (the alternates explored during
// design are clean mic-on-gradient variants) and re-run ./make-icon.sh.

let S = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

let rect = NSRect(x: 0, y: 0, width: S, height: S)
let radius = S * 0.2237   // full-bleed macOS squircle corner
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

// ---- Background: deep navy / near-black, subtle vertical gradient ----
let bg = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 0.13, green: 0.16, blue: 0.24, alpha: 1).cgColor,
    NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// Soft radial glow behind the ring to lift the center
let glow = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 0.30, green: 0.10, blue: 0.16, alpha: 0.55).cgColor,
    NSColor(srgbRed: 0.30, green: 0.10, blue: 0.16, alpha: 0.0).cgColor] as CFArray,
    locations: [0, 1])!
let center = CGPoint(x: S/2, y: S/2)
cg.drawRadialGradient(glow, startCenter: center, startRadius: 0,
    endCenter: center, endRadius: S * 0.42, options: [])

// ---- Record RING: bold red stroked circle ----
let ringLineWidth = S * 0.058
let ringRadius = S * 0.315
let ringRect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
    width: ringRadius * 2, height: ringRadius * 2)

// Drop shadow for depth on the ring
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10),
    blur: 28, color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55).cgColor)
let ringPath = CGMutablePath()
ringPath.addEllipse(in: ringRect)
cg.addPath(ringPath)
cg.setStrokeColor(NSColor(srgbRed: 0.93, green: 0.22, blue: 0.28, alpha: 1).cgColor)
cg.setLineWidth(ringLineWidth)
cg.strokePath()
cg.restoreGState()

// Glossy gradient overlay on the ring (clip to annulus, draw vertical gradient)
cg.saveGState()
let outerR = ringRadius + ringLineWidth / 2
let innerR = ringRadius - ringLineWidth / 2
let annulus = CGMutablePath()
annulus.addEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR*2, height: outerR*2))
annulus.addEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR*2, height: innerR*2))
cg.addPath(annulus)
cg.clip(using: .evenOdd)
let ringGrad = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 1.0, green: 0.38, blue: 0.42, alpha: 1).cgColor,
    NSColor(srgbRed: 0.78, green: 0.10, blue: 0.18, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(ringGrad, start: CGPoint(x: 0, y: center.y + ringRadius),
    end: CGPoint(x: 0, y: center.y - ringRadius), options: [])
cg.restoreGState()

// ---- White mic.fill centered inside the ring ----
let micPoint = S * 0.37
let cfg = NSImage.SymbolConfiguration(pointSize: micPoint, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let z = sym.size
    // subtle shadow under the mic for separation
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -6),
        blur: 16, color: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45).cgColor)
    sym.draw(at: NSPoint(x: (S - z.width)/2, y: (S - z.height)/2 + S*0.005),
        from: .zero, operation: .sourceOver, fraction: 1.0)
    cg.restoreGState()
}

// ---- Subtle top inner highlight on the squircle for depth ----
let topGlow = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.10).cgColor,
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0).cgColor] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(topGlow, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S * 0.72), options: [])

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Recorder-1024.png"))
print("wrote Recorder-1024.png")
