import Foundation
import PastaCore

/// Classifies text captured outside the macOS clipboard monitor, such as the
/// iOS pasteboard, with the same detectors the Mac uses. The entry keeps its
/// detected type and metadata, so type filters and detected items work for it.
///
/// Extracted child entries and env-block splitting are deliberately left to
/// the Mac: the iOS history lists every row, and the detail view already
/// renders the detected values from the metadata.
public enum CapturedTextClassifier {
    public static func entry(
        content: String,
        sourceApp: String?,
        timestamp: Date = Date(),
        detector: ContentTypeDetector = ContentTypeDetector(),
        configuration: DetectorConfiguration = .default
    ) -> ClipboardEntry {
        let output = detector.detect(in: content, configuration: configuration)
        return ClipboardEntry(
            content: content,
            contentType: output.primaryType == .unknown ? .text : output.primaryType,
            timestamp: timestamp,
            sourceApp: sourceApp,
            metadata: output.metadataJSON
        )
    }
}
