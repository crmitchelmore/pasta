import PastaCore
import XCTest
@testable import PastaDetectors

final class DetectorStrictnessTests: XCTestCase {
    private typealias Support = DetectorTestSupport

    func testPhoneNumberStrictnessSuppressesNoisyNumericBlobsAtMedium() throws {
        let phone = PhoneNumberDetector()
        let cases: [(name: String, strictness: DetectorStrictness, text: String, advanced: [String], expected: Int)] = [
            ("medium rejects long unformatted blobs", .medium, "Order IDs: 202602191651 19105072027582 35938854136 8589934595", [], 0),
            ("lax allows unformatted numbers", .lax, "Order IDs: 202602191651 19105072027582", [], 2),
            ("strict accepts conventional formatting", .strict, "Call +1 415-555-0199 or (020) 7123 4567", [], 2),
        ]
        for c in cases {
            XCTAssertEqual(phone.detect(in: c.text, strictness: c.strictness, advancedPatterns: c.advanced).count,
                           c.expected, "case \(c.name)")
        }
        XCTAssertEqual(
            phone.detect(in: "Internal extension ext-90210 is active", strictness: .strict,
                         advancedPatterns: [#"ext-(\d{5})"#]).map(\.phoneNumber),
            ["90210"], "advanced capture group overrides built-in rules"
        )

        // The same rule must hold through the real entry point and global strictness.
        let detector = ContentTypeDetector()
        let text = "IDs: 202602191651 19105072027582"
        var config = DetectorConfiguration.default
        config.globalStrictness = .medium
        XCTAssertNil(Support.parseJSON(detector.detect(in: text, configuration: config).metadataJSON)?["phoneNumbers"])
        config.globalStrictness = .lax
        let lax = Support.parseJSON(detector.detect(in: text, configuration: config).metadataJSON)
        XCTAssertEqual((lax?["phoneNumbers"] as? [[String: Any]])?.count, 2)
    }

    func testStructuredDetectorStrictnessTable() {
        let mac: (String, DetectorStrictness) -> [String] = { MACAddressDetector().detect(in: $0, strictness: $1).map(\.normalized) }
        let card: (String, DetectorStrictness) -> [String] = {
            CreditCardDetector().detect(in: $0, strictness: $1).map { "\($0.brand):\($0.normalized)" }
        }
        let iban: (String, DetectorStrictness) -> [String] = { IBANDetector().detect(in: $0, strictness: $1).map(\.normalized) }
        let dashAndCisco = "00-1A-2B-3C-4D-5E and 0011.2233.4455"
        let cases: [(name: String, detect: (String, DetectorStrictness) -> [String], input: String, strictness: DetectorStrictness, expected: [String])] = [
            ("mac strict colon form", mac, "iface 00:1A:2B:3C:4D:5E up", .strict, ["00:1A:2B:3C:4D:5E"]),
            ("mac strict rejects dash and cisco", mac, dashAndCisco, .strict, []),
            ("mac medium accepts dash only", mac, dashAndCisco, .medium, ["00:1A:2B:3C:4D:5E"]),
            ("mac lax accepts cisco", mac, "0011.2233.4455", .lax, ["00:11:22:33:44:55"]),
            ("mac lax dedupes across formats", mac, "00:11:22:33:44:55 / 00-11-22-33-44-55 / 0011.2233.4455", .lax, ["00:11:22:33:44:55"]),
            ("mac rejects junk", mac, "GG:HH:II:JJ:KK:LL", .lax, []),
            ("mac rejects short", mac, "00:1A:2B:3C:4D", .lax, []),
            ("card medium keeps unknown brand", card, "9999999999999995", .medium, ["Other:9999999999999995"]),
            ("card strict rejects unknown brand", card, "9999999999999995", .strict, []),
            ("iban strict requires known country", iban, "ZZ00 0000 0000 0000 0000 00", .strict, []),
        ]
        for c in cases {
            XCTAssertEqual(c.detect(c.input, c.strictness), c.expected, "case \(c.name)")
        }

        let detector = ContentTypeDetector()
        func colorConfig(_ strictness: DetectorStrictnessOverride) -> DetectorConfiguration {
            var config = DetectorConfiguration.default
            var rule = config.rule(for: .color)
            rule.strictnessOverride = strictness
            config.setRule(rule, for: .color)
            return config
        }
        XCTAssertEqual(detector.detect(in: "#ff0000", configuration: colorConfig(.strict)).primaryType, .color)
        XCTAssertNotEqual(detector.detect(in: "the value is #ff0000 here", configuration: colorConfig(.strict)).primaryType, .color,
                          "strict colour requires the whole input")
        XCTAssertEqual(detector.detect(in: "#ff8800", configuration: colorConfig(.medium)).primaryType, .color)
        let lax = detector.detect(in: "I love the color cornflowerblue.", configuration: colorConfig(.lax))
        XCTAssertTrue(lax.metadataJSON?.contains("cornflowerblue") ?? false, "lax extracts named colours from prose")
    }

    func testStoredConfigurationDrivesAdvancedPatternsAndCustomDetectors() throws {
        let suiteName = "DetectorStrictnessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var config = DetectorConfiguration.default
        for kind in BuiltInDetectorKind.allCases {
            XCTAssertNotNil(config.builtInRules[kind.rawValue], "default rule for \(kind.rawValue)")
        }
        config.globalStrictness = .strict
        var phoneRule = config.rule(for: .phoneNumber)
        phoneRule.strictnessOverride = .lax
        phoneRule.useAdvancedPatterns = true
        phoneRule.advancedPatterns = [#"ext-(\d{5})"#, "  "]
        config.setRule(phoneRule, for: .phoneNumber)
        config.customDetectors = [
            CustomDetectorDefinition(name: "Ticket ID", pattern: #"TKT-(\d{4})"#, isEnabled: true, isCaseInsensitive: false, confidence: 0.8),
            CustomDetectorDefinition(name: "Disabled", pattern: "Created", isEnabled: false, isCaseInsensitive: false, confidence: 0.8),
        ]

        try DetectorConfigurationStore.save(config, userDefaults: defaults)
        let loaded = DetectorConfigurationStore.load(userDefaults: defaults)
        XCTAssertEqual(loaded.globalStrictness, .strict)
        XCTAssertEqual(loaded.strictness(for: .phoneNumber), .lax)
        XCTAssertEqual(loaded.rule(for: .phoneNumber).cleanedPatterns, [#"ext-(\d{5})"#])

        let output = ContentTypeDetector().detect(in: "Created ticket TKT-4821 for ext-90210 yesterday", configuration: loaded)
        XCTAssertEqual(output.customDetections.map(\.name), ["Ticket ID"])
        XCTAssertEqual(output.customDetections.first?.value, "4821")
        let metadata = try XCTUnwrap(Support.parseJSON(output.metadataJSON))
        let custom = metadata["customDetectors"] as? [[String: Any]]
        XCTAssertEqual(custom?.first?["value"] as? String, "4821")
        let phones = metadata["phoneNumbers"] as? [[String: Any]]
        XCTAssertEqual(phones?.compactMap { $0["number"] as? String }, ["90210"])

        DetectorConfigurationStore.reset(userDefaults: defaults)
        XCTAssertEqual(DetectorConfigurationStore.load(userDefaults: defaults), .default)
    }

    func testBuiltInPresetsCompileAndAdvancedRegexRatingsAreCached() {
        for kind in BuiltInDetectorKind.allCases {
            for strictness in DetectorStrictness.allCases {
                let presets = kind.builtInPatterns(for: strictness)
                XCTAssertFalse(presets.isEmpty, "\(kind.rawValue) missing presets for \(strictness.rawValue)")
                for pattern in presets {
                    XCTAssertTrue(RegexPerformanceEvaluator.isValid(pattern: pattern), "\(kind.rawValue)/\(strictness.rawValue): \(pattern)")
                }
            }
        }
        for kind in [BuiltInDetectorKind.phoneNumber, .url, .apiKey] {
            XCTAssertNotEqual(kind.builtInPatterns(for: .strict), kind.builtInPatterns(for: .lax), kind.rawValue)
        }

        XCTAssertTrue(RegexPerformanceEvaluator.isValid(pattern: "ABC", options: [.caseInsensitive]))
        XCTAssertFalse(RegexPerformanceEvaluator.isValid(pattern: "([unterminated"))
        XCTAssertFalse(RegexPerformanceEvaluator.isValid(pattern: "   "))

        let cache = RegexPerformanceCache(limit: 3)
        let pattern = #"\b[A-Z]{3}-\d{4}\b"#
        let first = cache.result(pattern: pattern)
        // The benchmark timing is baked into `details`, so equality proves no re-run.
        XCTAssertEqual(cache.result(pattern: pattern), first)
        XCTAssertEqual(cache.cached(.init(patterns: [pattern], options: [])), first)
        _ = cache.result(pattern: pattern, options: [.caseInsensitive])
        XCTAssertEqual(cache.count, 2, "options are part of the key")
        let list = cache.result(patterns: ["[0-9]+", "[a-z]+"])
        XCTAssertEqual(cache.result(patterns: ["[0-9]+", "[a-z]+"]), list)
        XCTAssertEqual(cache.count, 3)

        let invalid = cache.result(pattern: "([unterminated")
        XCTAssertEqual(invalid.rating, .invalid)
        XCTAssertNotNil(invalid.compileError)
        XCTAssertEqual(cache.count, 3, "bounded cache evicts the oldest entry")
        XCTAssertNil(cache.cached(.init(patterns: [pattern], options: [])))
        XCTAssertEqual(cache.result(pattern: "([unterminated"), invalid)
    }
}
