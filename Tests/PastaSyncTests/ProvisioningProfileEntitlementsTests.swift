import XCTest
@testable import PastaSync

final class ProvisioningProfileEntitlementsTests: XCTestCase {
    /// Wraps a plist in junk bytes the way a CMS signature envelope does.
    private func profile(entitlements: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements, "Name": "Test"], format: .xml, options: 0)
        var blob = Data([0x30, 0x82, 0x0a, 0xff, 0x06, 0x09]) // ASN.1-ish prefix
        blob.append(plist)
        blob.append(Data(repeating: 0xab, count: 64)) // trailing signature bytes
        return blob
    }

    func testGrantsCloudKitWhenContainerIsListed() throws {
        let data = try profile(entitlements: [
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.pasta.ios"],
        ])
        XCTAssertTrue(ProvisioningProfileEntitlements.grantsCloudKit(containerIdentifier: "iCloud.com.pasta.ios", profileData: data))
        XCTAssertTrue(ProvisioningProfileEntitlements.grantsCloudKit(containerIdentifier: nil, profileData: data))
    }

    func testDeniesWhenRequestedContainerIsNotGranted() throws {
        let data = try profile(entitlements: [
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.example.other"],
        ])
        XCTAssertFalse(ProvisioningProfileEntitlements.grantsCloudKit(containerIdentifier: "iCloud.com.pasta.ios", profileData: data))
    }

    func testDeniesWhenProfileHasNoCloudKitEntitlement() throws {
        let data = try profile(entitlements: ["application-identifier": "TEAM.com.pasta.ios", "aps-environment": "production"])
        XCTAssertFalse(ProvisioningProfileEntitlements.grantsCloudKit(containerIdentifier: nil, profileData: data))
    }

    func testDeniesOnMalformedOrEmptyData() {
        XCTAssertFalse(ProvisioningProfileEntitlements.grantsCloudKit(containerIdentifier: nil, profileData: Data()))
        XCTAssertFalse(ProvisioningProfileEntitlements.grantsCloudKit(containerIdentifier: nil, profileData: Data("<?xml version=\"1.0\"?><plist><dict>".utf8)))
    }

    func testDeniesWhenBundleHasNoEmbeddedProfile() {
        // The test bundle (like the simulator and unsigned builds) ships no embedded.mobileprovision.
        XCTAssertFalse(ProvisioningProfileEntitlements.grantsCloudKit(containerIdentifier: "iCloud.com.pasta.ios", bundle: Bundle(for: Self.self)))
    }
}
