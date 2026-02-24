import XCTest
@testable import PastaDetectors

final class DetectorConfigurationTests: XCTestCase {
    func testDefaultConfigurationIncludesAllBuiltInDetectors() {
        let config = DetectorConfiguration.default
        for detector in BuiltInDetectorKind.allCases {
            XCTAssertNotNil(config.builtInRules[detector.rawValue])
        }
        XCTAssertEqual(config.globalStrictness, .medium)
    }

    func testSaveLoadRoundTrip() throws {
        let suiteName = "DetectorConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var config = DetectorConfiguration.default
        config.globalStrictness = .strict
        var phoneRule = config.rule(for: .phoneNumber)
        phoneRule.strictnessOverride = .lax
        phoneRule.useAdvancedPatterns = true
        phoneRule.advancedPatterns = [#"ext-(\d+)"#]
        config.setRule(phoneRule, for: .phoneNumber)
        config.customDetectors = [
            CustomDetectorDefinition(name: "Ticket", pattern: #"TKT-\d{4}"#, isEnabled: true, isCaseInsensitive: false, confidence: 0.8)
        ]

        try DetectorConfigurationStore.save(config, userDefaults: defaults)
        let loaded = DetectorConfigurationStore.load(userDefaults: defaults)

        XCTAssertEqual(loaded.globalStrictness, .strict)
        XCTAssertEqual(loaded.rule(for: .phoneNumber).strictnessOverride, .lax)
        XCTAssertEqual(loaded.rule(for: .phoneNumber).useAdvancedPatterns, true)
        XCTAssertEqual(loaded.rule(for: .phoneNumber).cleanedPatterns, [#"ext-(\d+)"#])
        XCTAssertEqual(loaded.customDetectors.first?.name, "Ticket")
    }
}
