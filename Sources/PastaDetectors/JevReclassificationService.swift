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
        extractContent: Bool
    ) throws -> Outcome {
        guard configuration.provider == .jev,
              classification.category != .unknown,
              JevEligibility.skipReason(for: snapshot, configuration: configuration) == nil else { return .retained }
        let detector = ContentTypeDetector()
        let local = detector.detect(in: snapshot.content, configuration: detectorConfiguration)
        guard JevEligibility.skipReason(contentType: local.primaryType, content: snapshot.content, configuration: configuration) == nil else {
            return .retained
        }
        let output = detector.detect(in: snapshot.content, configuration: detectorConfiguration, primaryTypeOverride: classification.category)
        let children: [ClipboardEntry] = extractContent ? output.extractedItems.map {
            ClipboardEntry(content: $0.content, contentType: $0.contentType, timestamp: snapshot.timestamp,
                           sourceApp: snapshot.sourceApp, metadata: $0.metadataJSON, parentEntryId: snapshot.id,
                           cloudSyncAllowed: snapshot.cloudSyncAllowed, receivedViaTailnet: snapshot.receivedViaTailnet)
        } : []
        let applied = try database.applyClassification(matching: snapshot, contentType: output.primaryType,
                                                      metadata: output.metadataJSON, extractedEntries: children)
        return applied ? .applied : .changedSinceRequest
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
