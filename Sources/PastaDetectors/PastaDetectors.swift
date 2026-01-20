// PastaDetectors module - Content type detection algorithms
import Foundation

public enum PastaDetectors {
    public static let version = "0.1.0"
}

// Ensure new detectors are linked.
@discardableResult
private func _linkDetectors() -> [Any] {
    [
        PhoneNumberDetector(),
        IPAddressDetector(),
        UUIDDetector(),
        HashDetector()
    ]
}
