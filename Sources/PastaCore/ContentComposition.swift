import Foundation

/// Composition is independent of the primary type and never changes paste or preview behaviour.
public enum ContentComposition {
    public static let extractionLimit = ContentExtractionConfiguration.defaultMaximum
    public static let analysisLimit = 30_000

    public static func metadata(
        _ metadata: String?,
        content: String,
        values: [(type: ContentType, value: String)],
        analysisTruncated: Bool,
        valuesTruncated: Bool = false,
        extractionConfiguration: ContentExtractionConfiguration = .default,
        eligibleItemCount: Int? = nil
    ) throws -> String? {
        guard !values.isEmpty || analysisTruncated else { return metadata }
        var object: [String: Any] = [:]
        if let metadata {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            object = parsed
        }

        var remainder = content
        var counts: [String: Int] = [:]
        for item in values {
            let kind = item.type == .envVarBlock ? ContentType.envVar : item.type
            counts[kind.rawValue, default: 0] += 1
        }
        // Longest first prevents a contained match from leaving part of a larger value behind.
        for value in Set(values.map(\.value)).sorted(by: { $0.utf16.count > $1.utf16.count }) {
            remainder = remainder.replacingOccurrences(of: value, with: " ")
        }
        let hasSurroundingText = remainder.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        object["composition"] = [
            "isMixed": counts.count > 1 || (!values.isEmpty && !valuesTruncated && hasSurroundingText),
            "counts": counts,
            "itemCount": values.count,
            "extractionLimit": extractionConfiguration.maximumSavedItems,
            "eligibleItemCount": eligibleItemCount ?? values.count,
            "analysisTruncated": analysisTruncated,
            "summaryTruncated": valuesTruncated
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func backfilledMetadata(_ metadata: String?, content: String) throws -> String? {
        let analyzed = String(content.prefix(analysisLimit))
        let supported = MetadataParser.extractableTypes.union([.text])
        let candidates = MetadataParser.extractAllValues(from: metadata, limit: 1_001, content: content)
        guard !candidates.isEmpty else { return metadata }
        let trimmed = analyzed.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        let values = candidates.prefix(1_000).filter {
            supported.contains($0.type) && !$0.value.isEmpty && $0.value != trimmed &&
            analyzed.contains($0.value) && seen.insert("\($0.type.rawValue):\($0.value)").inserted
        }.map { (type: $0.type, value: $0.value) }
        // A sampled historical summary must not mistake unseen list items for surrounding prose.
        return try self.metadata(metadata, content: analyzed, values: values,
                                 analysisTruncated: content.count > analysisLimit,
                                 valuesTruncated: candidates.count > 1_000)
    }
}
