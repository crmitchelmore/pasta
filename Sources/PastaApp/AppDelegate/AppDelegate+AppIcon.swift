import AppKit

extension AppDelegate {
    func configureAppIcon() {
        // Installed bundles and SwiftPM development bundles use the same artwork.
        // Do not replace the signed bundle icon with a separately drawn fallback.
        let image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:))
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png")
                .flatMap(NSImage.init(contentsOf:))
        if let image {
            NSApplication.shared.applicationIconImage = image
            NSApplication.shared.dockTile.display()
        }
    }
}
