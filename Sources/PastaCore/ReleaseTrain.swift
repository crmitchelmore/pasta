import Foundation

/// Distribution channel identities. Missing metadata belongs to existing Stable installations.
public enum ReleaseTrain: String, Codable, Sendable {
    case stable, alpha

    public static var current: Self {
        resolve(bundleIdentifier: Bundle.main.bundleIdentifier,
                metadata: Bundle.main.object(forInfoDictionaryKey: "PastaReleaseTrain") as? String)
    }

    public static func resolve(bundleIdentifier: String?, metadata: String?) -> Self {
        let identityIsAlpha = bundleIdentifier?.split(separator: ".").contains("alpha") == true
        if identityIsAlpha { return .alpha }
        return metadata == "alpha" ? .alpha : .stable
    }

    public var displayName: String { self == .alpha ? "Pasta Alpha" : "Pasta" }
    public var macBundleIdentifier: String { self == .alpha ? "com.pasta.clipboard.alpha" : "com.pasta.clipboard" }
    /// iOS Alpha is a TestFlight build of the one Pasta app (App Review Guideline 4.3(a)),
    /// so it shares the App Store bundle ID, CloudKit container and on-device data.
    public var iosBundleIdentifier: String { "com.pasta.ios" }
    public var iosCloudContainer: String { "iCloud.com.pasta.ios" }
    /// The direct macOS app's container. Mac Alpha stays isolated from Stable.
    public var cloudContainer: String { self == .alpha ? "iCloud.com.pasta.ios.alpha" : "iCloud.com.pasta.ios" }
    public var feedURL: String { self == .alpha ? "https://pasta-app.com/alpha/appcast.xml" : "https://pasta-app.com/appcast.xml" }
    public var tailnetPort: UInt16 { self == .alpha ? 45874 : 45873 }
    public func namespace(_ stable: String) -> String { self == .alpha ? stable + ".alpha" : stable }
    public func acceptsPeer(_ train: String?) -> Bool { (train ?? "stable") == rawValue }
    public func allowsGlobalShortcut(explicitlyChosen: Bool) -> Bool { self == .stable || explicitlyChosen }
}
