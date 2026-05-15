import SwiftUI

#if canImport(AppKit)
import AppKit

enum SourceAppIconResolver {
    private static var cache: [String: NSImage] = [:]

    static func image(for sourceApp: String?) -> NSImage? {
        guard let sourceApp = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceApp.isEmpty,
              sourceApp != "Unknown",
              sourceApp != "Continuity" else {
            return nil
        }

        if let cached = cache[sourceApp] {
            return cached
        }

        guard sourceApp.contains("."),
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceApp) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        cache[sourceApp] = image
        return image
    }

    static func fallbackSystemImageName(for sourceApp: String?) -> String {
        switch sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Continuity":
            return "iphone"
        case .some(let value) where value.isEmpty:
            return "questionmark.app"
        case .none, "Unknown":
            return "questionmark.app"
        default:
            return "app"
        }
    }
}

struct SourceAppIconView: View {
    let sourceApp: String?
    let size: CGFloat

    init(sourceApp: String?, size: CGFloat = 16) {
        self.sourceApp = sourceApp
        self.size = size
    }

    var body: some View {
        Group {
            if let image = SourceAppIconResolver.image(for: sourceApp) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: SourceAppIconResolver.fallbackSystemImageName(for: sourceApp))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}
#else
struct SourceAppIconView: View {
    let sourceApp: String?
    let size: CGFloat

    init(sourceApp: String?, size: CGFloat = 16) {
        self.sourceApp = sourceApp
        self.size = size
    }

    var body: some View {
        Image(systemName: sourceApp == "Continuity" ? "iphone" : "app")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}
#endif
