#!/bin/bash
# Generate DMG background image using native macOS tools (sips + Core Graphics via Swift)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/background.png"
OUTPUT_2X="$SCRIPT_DIR/background@2x.png"

# Use Swift to generate the background image
swift - <<'SWIFT'
import Cocoa

let width: CGFloat = 660
let height: CGFloat = 400
let scale: CGFloat = 2  // Retina

// Colors matching Pasta theme
let backgroundColor = NSColor(red: 30/255, green: 30/255, blue: 32/255, alpha: 1)
let accentColor = NSColor(red: 255/255, green: 115/255, blue: 90/255, alpha: 1)
let textColor = NSColor(red: 180/255, green: 180/255, blue: 185/255, alpha: 1)

// Icon positions
let appIconX: CGFloat = 180
let appsIconX: CGFloat = 480
let iconY: CGFloat = 200

func createImage(scaleFactor: CGFloat) -> NSImage {
    let w = width * scaleFactor
    let h = height * scaleFactor
    let s = scaleFactor
    
    let image = NSImage(size: NSSize(width: w, height: h))
    image.lockFocus()
    
    // Background
    backgroundColor.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    
    // Subtle gradient overlay
    let gradient = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.03),
        NSColor(white: 1, alpha: 0)
    ])
    gradient?.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
    
    // Arrow coordinates (flip Y for Cocoa)
    let arrowY = (height - iconY) * s
    let arrowStartX = (appIconX + 60) * s
    let arrowEndX = (appsIconX - 60) * s
    
    // Draw arrow glow
    for offset in stride(from: 12, through: 2, by: -2) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: arrowStartX, y: arrowY))
        path.line(to: NSPoint(x: arrowEndX - 20 * s, y: arrowY))
        accentColor.withAlphaComponent(0.1).setStroke()
        path.lineWidth = CGFloat(3 + offset) * s
        path.stroke()
    }
    
    // Draw main arrow line
    let arrowPath = NSBezierPath()
    arrowPath.move(to: NSPoint(x: arrowStartX, y: arrowY))
    arrowPath.line(to: NSPoint(x: arrowEndX - 15 * s, y: arrowY))
    accentColor.setStroke()
    arrowPath.lineWidth = 4 * s
    arrowPath.lineCapStyle = .round
    arrowPath.stroke()
    
    // Draw arrowhead
    let arrowHead = NSBezierPath()
    let headSize: CGFloat = 12 * s
    arrowHead.move(to: NSPoint(x: arrowEndX, y: arrowY))
    arrowHead.line(to: NSPoint(x: arrowEndX - headSize, y: arrowY + headSize * 0.6))
    arrowHead.line(to: NSPoint(x: arrowEndX - headSize, y: arrowY - headSize * 0.6))
    arrowHead.close()
    accentColor.setFill()
    arrowHead.fill()
    
    // Draw dashed circle around app icon position
    let appCircle = NSBezierPath(ovalIn: NSRect(
        x: appIconX * s - 65 * s,
        y: arrowY - 65 * s,
        width: 130 * s,
        height: 130 * s
    ))
    NSColor(white: 0.4, alpha: 0.5).setStroke()
    appCircle.lineWidth = 2 * s
    let dashPattern: [CGFloat] = [12 * s, 8 * s]
    appCircle.setLineDash(dashPattern, count: 2, phase: 0)
    appCircle.stroke()
    
    // Draw dashed circle around Applications position
    let appsCircle = NSBezierPath(ovalIn: NSRect(
        x: appsIconX * s - 65 * s,
        y: arrowY - 65 * s,
        width: 130 * s,
        height: 130 * s
    ))
    accentColor.withAlphaComponent(0.6).setStroke()
    appsCircle.lineWidth = 2 * s
    appsCircle.setLineDash(dashPattern, count: 2, phase: 0)
    appsCircle.stroke()
    
    // Draw text labels
    let font = NSFont.systemFont(ofSize: 13 * s, weight: .medium)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: paragraphStyle
    ]
    
    // "Drag" label
    let dragText = "Drag" as NSString
    let dragSize = dragText.size(withAttributes: textAttrs)
    dragText.draw(
        at: NSPoint(x: appIconX * s - dragSize.width / 2, y: arrowY - 100 * s),
        withAttributes: textAttrs
    )
    
    // "to Applications" label  
    let appsText = "to Applications" as NSString
    let appsSize = appsText.size(withAttributes: textAttrs)
    appsText.draw(
        at: NSPoint(x: appsIconX * s - appsSize.width / 2, y: arrowY - 100 * s),
        withAttributes: textAttrs
    )
    
    image.unlockFocus()
    return image
}

// Create 2x image
let image2x = createImage(scaleFactor: 2)
if let tiff = image2x.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiff),
   let png = bitmap.representation(using: .png, properties: [:]) {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("background@2x.png")
    try? png.write(to: url)
    print("Created: \(url.path)")
}

// Create 1x image
let image1x = createImage(scaleFactor: 1)
if let tiff = image1x.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiff),
   let png = bitmap.representation(using: .png, properties: [:]) {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("background.png")
    try? png.write(to: url)
    print("Created: \(url.path)")
}
SWIFT

echo "==> Background images created"
ls -la "$SCRIPT_DIR"/background*.png
