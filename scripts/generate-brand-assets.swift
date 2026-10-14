#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Deterministic platform exports from the unmasked, opaque master artwork.
// Run from the repository root: swift scripts/generate-brand-assets.swift
let isAlpha = CommandLine.arguments.contains("--alpha")
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let masterURL = root.appendingPathComponent(isAlpha ? "Resources/Branding/AppIconAlpha-master.png" : "Resources/Branding/AppIcon-master.png")
guard let master = NSImage(contentsOf: masterURL) else { fatalError("Missing icon master") }

func export(_ path: String, size: Int, macOS: Bool = false) throws {
    let alpha = macOS ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    guard let bitmap = CGContext(data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: alpha.rawValue) else { fatalError("Cannot create bitmap") }
    let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill(using: .copy)
    let rect = macOS ? canvas.insetBy(dx: CGFloat(size) * 0.06, dy: CGFloat(size) * 0.06) : canvas
    if macOS {
        NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) * 0.195, yRadius: CGFloat(size) * 0.195).addClip()
    }
    master.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = bitmap.makeImage(),
        let output = CGImageDestinationCreateWithURL(root.appendingPathComponent(path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { fatalError("PNG encoding failed") }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("PNG write failed") }
    print("\(path): \(size)px, \(macOS ? "macOS mask" : "opaque")")
}

for (originalFolder, macOS) in [
    ("Sources/PastaApp/Resources/Assets.xcassets/AppIcon.appiconset", true),
    ("PastaIOS/PastaIOS/Assets.xcassets/AppIcon.appiconset", false)
] {
    let folder = isAlpha ? originalFolder.replacingOccurrences(of: "AppIcon.appiconset", with: "AppIconAlpha.appiconset") : originalFolder
    try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    let contents = try Data(contentsOf: root.appendingPathComponent(originalFolder + "/Contents.json"))
    if isAlpha { try contents.write(to: root.appendingPathComponent(folder + "/Contents.json")) }
    let json = try JSONSerialization.jsonObject(with: contents) as! [String: Any]
    let images = json["images"] as! [[String: Any]]
    var written = Set<String>()
    for entry in images {
        guard let filename = entry["filename"] as? String, written.insert(filename).inserted else { continue }
        let points = Double((entry["size"] as! String).split(separator: "x")[0])!
        let scale = Double((entry["scale"] as? String ?? "1x").dropLast())!
        try export(folder + "/" + filename, size: Int((points * scale).rounded()), macOS: macOS)
    }
    // Remove legacy exports that are not used by the asset catalogue.
    for url in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
        where url.pathExtension == "png" && !written.contains(url.lastPathComponent) {
        try FileManager.default.removeItem(at: url)
    }
}
if isAlpha {
    try export("Sources/PastaApp/Resources/AppIconAlpha.png", size: 1024, macOS: true)
    // Builds and size-optimises both trains' committed ICNS from the appiconsets.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["Resources/DMG/create-icns.sh"]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("Alpha ICNS generation failed") }
    exit(0)
}
try export("Sources/PastaApp/Resources/AppIcon.png", size: 1024, macOS: true)
// Landing-page icons are rendered at their exact 2x/3x display sizes (40/72 pt).
for (name, size) in [("app-icon-v3-144.png", 144), ("app-icon-v3-216.png", 216), ("apple-touch-icon-v2.png", 180), ("favicon-32x32-v2.png", 32), ("favicon-16x16-v2.png", 16)] {
    try export("landing-page/images/" + name, size: size)
}

// iOS onboarding shows the mark at 96 pt, so 288 px covers 3x displays exactly.
try export("PastaIOS/PastaIOS/Assets.xcassets/PastaMark.imageset/PastaMark.png", size: 288)
