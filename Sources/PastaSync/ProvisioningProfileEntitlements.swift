import Foundation

/// Reads the entitlements a signed iOS build was actually granted, using only
/// public APIs, so `SyncManager` can decide whether constructing a
/// `CKContainer` is safe.
///
/// `CKContainer(identifier:)` raises an uncatchable `SIGTRAP` when the running
/// binary lacks the CloudKit entitlement for that container. iOS offers no
/// public runtime entitlement API (the `SecTask*` symbols are private there and
/// were rejected by App Store validation in #85), but every device build ships
/// its provisioning profile as `embedded.mobileprovision`, a CMS blob wrapping
/// a plist whose `Entitlements` dictionary lists the granted iCloud containers.
/// Simulator and unsigned builds have no embedded profile and no entitlements,
/// so they report `false` and the app runs with sync unavailable instead of
/// crashing at launch.
enum ProvisioningProfileEntitlements {
    /// Whether the embedded provisioning profile grants CloudKit access to
    /// `containerIdentifier` (or to any container when `nil`).
    static func grantsCloudKit(containerIdentifier: String?, bundle: Bundle = .main) -> Bool {
        guard let path = bundle.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = FileManager.default.contents(atPath: path)
        else { return false }
        return grantsCloudKit(containerIdentifier: containerIdentifier, profileData: data)
    }

    /// Pure variant for tests: `profileData` is the raw `.mobileprovision` bytes.
    static func grantsCloudKit(containerIdentifier: String?, profileData: Data) -> Bool {
        guard let entitlements = entitlements(fromProfileData: profileData) else { return false }
        let services = entitlements["com.apple.developer.icloud-services"] as? [String] ?? []
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
        guard services.contains("CloudKit") || !containers.isEmpty else { return false }
        guard let containerIdentifier else { return true }
        return containers.contains(containerIdentifier)
    }

    /// Extracts the `Entitlements` dictionary from a CMS-wrapped profile by
    /// locating the embedded XML plist.
    static func entitlements(fromProfileData data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8))?.lowerBound,
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start..<data.endIndex)?.upperBound
        else { return nil }
        let plistData = data.subdata(in: start..<end)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        return dict["Entitlements"] as? [String: Any]
    }
}
