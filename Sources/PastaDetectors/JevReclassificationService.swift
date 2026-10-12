import Foundation
import PastaCore

public struct JevReclassificationService {
    public init() {}

    public enum Outcome: Sendable, Equatable {
        case applied
        case retained
        case changedSinceRequest
    }

    public func apply(
        _ classification: JevClassification,
        to snapshot: ClipboardEntry,
        database: DatabaseManager,
        configuration: JevConfiguration,
        detectorConfiguration: DetectorConfiguration,
        extractContent: Bool,
        skipAPIKeys: Bool
    ) throws -> Outcome {
        guard classification.category != .unknown,
              JevEligibility.skipReason(for: snapshot, configuration: configuration) == nil else { return .retained }
        let detector = ContentTypeDetector()
        let local = detector.detect(in: snapshot.content, configuration: detectorConfiguration)
        guard JevEligibility.skipReason(contentType: local.primaryType, content: snapshot.content, configuration: configuration) == nil else {
            return .retained
        }
        let output = detector.detect(in: snapshot.content, configuration: detectorConfiguration, primaryTypeOverride: classification.category)
        guard !(skipAPIKeys && output.primaryType == .apiKey) else { return .retained }
        let children: [ClipboardEntry] = extractContent ? output.extractedItems.filter {
            !(skipAPIKeys && $0.contentType == .apiKey)
        }.map {
            ClipboardEntry(content: $0.content, contentType: $0.contentType, timestamp: snapshot.timestamp,
                           sourceApp: snapshot.sourceApp, metadata: $0.metadataJSON, parentEntryId: snapshot.id,
                           cloudSyncAllowed: snapshot.cloudSyncAllowed, receivedViaTailnet: snapshot.receivedViaTailnet)
        } : []
        var metadata = output.metadataJSON
        if let custom = configuration.rules.customClassifier(for: classification.rawChoice) {
            var object: [String: Any] = [:]
            if let data = metadata?.data(using: .utf8) {
                guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw JevConfigurationError.invalidResponse
                }
                object = dictionary
            }
            object["decisionClassification"] = ["label": custom.name, "choice": custom.choiceID,
                                                "provider": configuration.provider.rawValue,
                                                "model": classification.modelVersion ?? configuration.effectiveModel]
            metadata = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        let applied = try database.applyClassification(matching: snapshot, contentType: output.primaryType,
                                                      metadata: metadata, extractedEntries: children)
        return applied ? .applied : .changedSinceRequest
    }

    public static func applicationSummary(total: Int, updated: Int, changedDeleted: Int, providerFailures: Int) -> String {
        let retained = max(0, total - updated - changedDeleted - providerFailures)
        return "\(updated) updated · \(retained) retained · \(changedDeleted) changed/deleted · \(providerFailures) provider failures."
    }
}

/// Live traffic is serialized and bounded independently of clipboard capture.
public actor JevLiveQueue {
    public static let shared = JevLiveQueue()
    private var jobs: [@Sendable () async -> Void] = []
    private var isRunning = false
    private let capacity: Int

    public init(capacity: Int = 50) { self.capacity = max(1, capacity) }

    public func enqueue(_ job: @escaping @Sendable () async -> Void) -> Bool {
        guard jobs.count < capacity else { return false }
        jobs.append(job)
        if !isRunning {
            isRunning = true
            Task { await drain() }
        }
        return true
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            await job()
        }
        isRunning = false
    }
}
