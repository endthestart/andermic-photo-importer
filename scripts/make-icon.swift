// Draws Assets/AppIcon.png from the SENEX family icon template in docs/DESIGN-TOKENS.md:
// a night-sky tile with the Corvus (Crow) constellation as the emblem.
// Usage: make-icon <output.png>
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

let S = 1024.0, pad = 100.0, tileRadius = 185.0
let accent = (143.0, 180.0, 255.0)
let dotSeed: UInt64 = 11, treeSeed: UInt64 = 5
/// J2000 right ascension and declination in degrees, and V magnitude.
let stars: [String: (ra: Double, dec: Double, v: Double)] = [
    "α": (182.103, -24.729, 4.02), "ε": (182.531, -22.620, 3.00), "γ": (183.951, -17.542, 2.59),
    "δ": (187.466, -16.516, 2.95), "β": (188.597, -23.397, 2.65),
]
let figure = ["α", "ε", "γ", "δ", "β", "ε"]

/// SplitMix64: a small deterministic generator, so the icon is reproducible.
struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * Double(next() >> 11) / Double(1 << 53) }
    mutating func integer(_ low: Int, _ high: Int) -> Int { low + Int(next() % UInt64(high - low + 1)) }
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: Double, _ g: Double, _ b: Double, _ alpha: Double = 255) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, alpha / 255])!
}
/// A transparent full-canvas layer with y pointing down, as the template's coordinates do.
func layer() -> CGContext {
    let context = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: S); context.scaleBy(x: 1, y: -1)
    return context
}
let ciContext = CIContext(options: [.workingColorSpace: space])
func blurred(_ context: CGContext, _ radius: Double) -> CGImage {
    let image = CIImage(cgImage: context.makeImage()!)
    let blur = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
    return ciContext.createCGImage(blur, from: image.extent)!
}
func composite(_ image: CGImage, onto context: CGContext) {
    context.saveGState(); context.translateBy(x: 0, y: S); context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(x: 0, y: 0, width: S, height: S)); context.restoreGState()
}
func circle(_ context: CGContext, _ x: Double, _ y: Double, _ r: Double) {
    context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

let canvas = layer()
// Gradient over the full canvas, one row at a time.
for row in 0..<Int(S) {
    let t = Double(row) / S
    canvas.setFillColor(color((10 + 14 * t).rounded(.down), (16 + 22 * t).rounded(.down), (36 + 42 * t).rounded(.down)))
    canvas.fill(CGRect(x: 0, y: Double(row), width: S, height: 1))
}

// Milky Way band: the union of the ellipses at alpha 10 (overlaps do not accumulate).
let band = layer()
band.setFillColor(color(150, 165, 230))
for k in 0..<60 {
    let t = Double(k) / 60
    let x = pad + 80 + t * (S - 2 * pad - 160), y = S * 0.62 - t * S * 0.38
    band.fillEllipse(in: CGRect(x: x - 120, y: y - 60, width: 240, height: 120))
}
canvas.saveGState(); canvas.setAlpha(10 / 255)
composite(blurred(band, 40), onto: canvas)
canvas.restoreGState()

// Background stars in the top 72% of the tile.
var dots = Random(state: dotSeed)
for _ in 0..<140 {
    let x = dots.uniform(pad, S - pad), y = dots.uniform(pad, S * 0.72)
    let r = [1.2, 1.6, 2.2, 2.8][dots.integer(0, 3)], alpha = Double(dots.integer(120, 255))
    canvas.setFillColor(color(220, 228, 255, alpha)); circle(canvas, x, y, r)
}

// Emblem: the figure projected with east to the left, fitted to 0.34S and centred at (0.50S, 0.36S).
let ras = stars.values.map(\.ra), decs = stars.values.map(\.dec)
let ra0 = (ras.min()! + ras.max()!) / 2, dec0 = (decs.min()! + decs.max()!) / 2, squeeze = cos(dec0 * .pi / 180)
let projected = stars.mapValues { (x: -($0.ra - ra0) * squeeze, y: -($0.dec - dec0)) }
let xs = projected.values.map(\.x), ys = projected.values.map(\.y)
let scale = 0.34 * S / max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
let position = projected.mapValues { (x: 0.5 * S + $0.x * scale, y: 0.36 * S + $0.y * scale) }

let lines = layer()
lines.setStrokeColor(color(accent.0, accent.1, accent.2, 150)); lines.setLineWidth(5); lines.setLineCap(.round)
for (from, to) in zip(figure, figure.dropFirst()) {
    lines.move(to: CGPoint(x: position[from]!.x, y: position[from]!.y)); lines.addLine(to: CGPoint(x: position[to]!.x, y: position[to]!.y))
}
lines.strokePath()
composite(lines.makeImage()!, onto: canvas)

for name in stars.keys.sorted() {
    let (x, y) = position[name]!
    let R = min(64, max(28, 64 - 16 * (stars[name]!.v - 2.6)))
    let halo = layer()
    halo.setFillColor(color(accent.0, accent.1, accent.2, 120)); circle(halo, x, y, R)
    composite(blurred(halo, 0.5 * R), onto: canvas)
    canvas.setFillColor(color(232, 240, 255))
    for k in 0..<8 {
        let radius = k % 2 == 0 ? R : 0.22 * R, angle = Double(k) * .pi / 4 - .pi / 2
        let point = CGPoint(x: x + radius * cos(angle), y: y + radius * sin(angle))
        if k == 0 { canvas.move(to: point) } else { canvas.addLine(to: point) }
    }
    canvas.closePath(); canvas.fillPath()
}

// Treeline over solid ground; drawn last so it covers anything low.
var trees = Random(state: treeSeed)
let base = S * 0.78
canvas.setFillColor(color(6, 9, 14))
canvas.move(to: CGPoint(x: pad, y: S - pad)); canvas.addLine(to: CGPoint(x: pad, y: base))
var x = pad
while x < S - pad {
    let w = trees.uniform(26, 52), h = trees.uniform(60, 190)
    canvas.addLine(to: CGPoint(x: x, y: base)); canvas.addLine(to: CGPoint(x: x + w / 2, y: base - h)); canvas.addLine(to: CGPoint(x: x + w, y: base))
    x += w * 0.8
}
canvas.addLine(to: CGPoint(x: S - pad, y: base)); canvas.addLine(to: CGPoint(x: S - pad, y: S - pad)); canvas.closePath(); canvas.fillPath()
canvas.fill(CGRect(x: pad, y: base, width: S - 2 * pad, height: S - pad - base))

// Tile mask.
let output = layer()
output.addPath(CGPath(roundedRect: CGRect(x: pad, y: pad, width: S - 2 * pad, height: S - 2 * pad), cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil))
output.clip()
composite(canvas.makeImage()!, onto: output)

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { fatalError("Cannot write \(url)") }
CGImageDestinationAddImage(destination, output.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url)") }
