import AppKit

extension AppDelegate {
    func configureAppIcon() {
        let iconName = NSImage.Name("AppIcon")
        let image = NSImage(named: iconName) ?? Self.makeFallbackIcon(size: 512)
        NSApplication.shared.applicationIconImage = image
        NSApplication.shared.dockTile.display()
    }

    static private func makeFallbackIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let corner = size * 0.22

        // Background gradient - modern blue-purple
        let backgroundPath = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        let bgGradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 1.0),  // Blue
            NSColor(calibratedRed: 0.42, green: 0.35, blue: 0.80, alpha: 1.0)   // Purple
        ])
        bgGradient?.draw(in: backgroundPath, angle: -45)

        // Draw stacked clipboard pages (history effect)
        let pageColors = [
            NSColor(white: 1.0, alpha: 0.3),
            NSColor(white: 1.0, alpha: 0.5),
            NSColor(white: 1.0, alpha: 0.85)
        ]

        for (index, color) in pageColors.enumerated() {
            let offset = CGFloat(2 - index) * size * 0.03
            let pageRect = NSRect(
                x: size * 0.18 + offset,
                y: size * 0.15 - offset,
                width: size * 0.64,
                height: size * 0.70
            )
            let pagePath = NSBezierPath(roundedRect: pageRect, xRadius: size * 0.06, yRadius: size * 0.06)
            color.setFill()
            pagePath.fill()
        }

        // Main clipboard page
        let mainPageRect = NSRect(x: size * 0.18, y: size * 0.15, width: size * 0.64, height: size * 0.70)
        let mainPage = NSBezierPath(roundedRect: mainPageRect, xRadius: size * 0.06, yRadius: size * 0.06)
        NSColor.white.setFill()
        mainPage.fill()

        // Clipboard clip at top
        let clipWidth = size * 0.28
        let clipHeight = size * 0.12
        let clipRect = NSRect(
            x: rect.midX - clipWidth / 2,
            y: size * 0.78,
            width: clipWidth,
            height: clipHeight
        )
        let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: size * 0.03, yRadius: size * 0.03)
        NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.58, alpha: 1.0).setFill()
        clipPath.fill()

        // Inner clip detail
        let innerClipRect = clipRect.insetBy(dx: size * 0.03, dy: size * 0.025)
        let innerClipPath = NSBezierPath(roundedRect: innerClipRect, xRadius: size * 0.015, yRadius: size * 0.015)
        NSColor(calibratedRed: 0.70, green: 0.70, blue: 0.72, alpha: 1.0).setFill()
        innerClipPath.fill()

        // Text lines on clipboard (representing content)
        let lineColor = NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.87, alpha: 1.0)
        let accentColor = NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 0.6)

        let lineY: [CGFloat] = [0.62, 0.52, 0.42, 0.32]
        let lineWidths: [CGFloat] = [0.42, 0.38, 0.32, 0.25]

        for (y, width) in zip(lineY, lineWidths) {
            let lineRect = NSRect(
                x: size * 0.26,
                y: size * y,
                width: size * width,
                height: size * 0.045
            )
            let linePath = NSBezierPath(roundedRect: lineRect, xRadius: size * 0.02, yRadius: size * 0.02)
            (y == 0.62 ? accentColor : lineColor).setFill()
            linePath.fill()
        }

        // Copy symbol (two overlapping squares) in corner
        let symbolSize = size * 0.14
        let symbolX = size * 0.58
        let symbolY = size * 0.22

        // Back square
        let backSquare = NSBezierPath(roundedRect: NSRect(
            x: symbolX + size * 0.03,
            y: symbolY + size * 0.03,
            width: symbolSize,
            height: symbolSize
        ), xRadius: size * 0.02, yRadius: size * 0.02)
        NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 0.4).setFill()
        backSquare.fill()

        // Front square
        let frontSquare = NSBezierPath(roundedRect: NSRect(
            x: symbolX,
            y: symbolY,
            width: symbolSize,
            height: symbolSize
        ), xRadius: size * 0.02, yRadius: size * 0.02)
        NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 0.8).setFill()
        frontSquare.fill()

        return image
    }
}
