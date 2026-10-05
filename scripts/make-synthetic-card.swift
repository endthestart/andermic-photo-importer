// Generates a synthetic camera card for GUI exercise and screenshots. No personal photos are used.
// Usage: make-synthetic-card <card-folder> [variant]  (a variant changes images and dates)
// RAW files are byte containers paired with dated JPEGs; they are not real camera RAW data.
import Foundation
import ImageIO
import CoreGraphics

let card = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let dcim = card.appendingPathComponent("DCIM/100SYNTH", isDirectory: true)
let fm = FileManager.default
let variant = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 0 : 0
try fm.createDirectory(at: dcim, withIntermediateDirectories: true)

func photo(_ name: String, date: String?, hue: CGFloat, seed: Int) throws {
    let width = 1200, height = 800
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func color(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6), p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        let (r, g, bl): (CGFloat, CGFloat, CGFloat) = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i]
        return CGColor(red: r, green: g, blue: bl, alpha: 1)
    }
    // Sky-to-ground gradient, a sun, and layered hills: enough variety to judge thumbnails.
    let gradient = CGGradient(colorsSpace: nil, colors: [color(hue, 0.55, 0.95), color((hue + 0.08).truncatingRemainder(dividingBy: 1), 0.35, 0.75)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
    context.setFillColor(color((hue + 0.12).truncatingRemainder(dividingBy: 1), 0.25, 1))
    context.fillEllipse(in: CGRect(x: 180 + (seed * 97) % 700, y: 480 + (seed * 31) % 140, width: 150, height: 150))
    for layer in 0..<3 {
        context.setFillColor(color((hue + 0.3 + CGFloat(layer) * 0.05).truncatingRemainder(dividingBy: 1), 0.5, 0.55 - CGFloat(layer) * 0.15))
        context.move(to: CGPoint(x: 0, y: 0))
        for x in stride(from: 0, through: width, by: 40) {
            let y = 260 - layer * 70 + Int(60 * sin(Double(x + seed * 53 + layer * 211) / 140.0))
            context.addLine(to: CGPoint(x: x, y: y))
        }
        context.addLine(to: CGPoint(x: width, y: 0)); context.closePath(); context.fillPath()
    }
    let url = dcim.appendingPathComponent(name)
    let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
    if let date { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
    CGImageDestinationAddImage(writer, context.makeImage()!, properties as CFDictionary)
    guard CGImageDestinationFinalize(writer) else { fatalError("Could not write \(name)") }
}

let days = variant == 0 ? ["2026:09:12", "2026:09:13", "2026:09:14"] : ["2026:10:0\(variant)", "2026:10:0\(variant + 1)", "2026:10:0\(variant + 2)"]
for index in 1...24 {
    let name = String(format: "DSC_%04d", index)
    let day = days[(index - 1) / 8]
    try photo(name + ".JPG", date: "\(day) \(String(format: "%02d", 8 + index % 10)):15:00", hue: (CGFloat(index) / 24 + CGFloat(variant) * 0.37).truncatingRemainder(dividingBy: 1), seed: index + variant * 100)
    if index % 3 == 0 {   // RAW+JPEG pairs; the synthetic RAW inherits the JPEG's capture day
        try Data((0..<4096).map { UInt8(($0 * index + variant) % 251) }).write(to: dcim.appendingPathComponent(name + ".NEF"))
    }
    if index % 6 == 0 {
        try Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rating>\(index % 5)</rating></x:xmpmeta>".utf8).write(to: dcim.appendingPathComponent(name + ".XMP"))
    }
}
try photo("DSC_0025.JPG", date: nil, hue: 0.62, seed: 25 + variant * 100)          // no capture date: needs an explicit fallback
try Data((0..<8192).map { UInt8(($0 + variant) % 13) }).write(to: dcim.appendingPathComponent("MVI_0026.MOV"))
try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: dcim.appendingPathComponent("MVI_0026.THM"))
try Data("orphan sidecar".utf8).write(to: dcim.appendingPathComponent("DSC_0099.XMP"))
print("Synthetic card written to \(card.path)")
