import Foundation

/// Consent, install identity and the daily-event marker, persisted as one small JSON file.
///
/// Reads fail closed: an unreadable or corrupt file is treated as "nothing recorded
/// yet", which means `.unknown` consent and no installation ID. A damaged file can
/// therefore never enable collection, and can never wedge start-up either.
public final class FileProductAnalyticsStateStore: ProductAnalyticsStateStore, @unchecked Sendable {
    private struct State: Codable {
        var consent: AnalyticsConsentState = .unknown
        var installationID: UUID?
        var lastDailyActiveDay: Date?
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func loadConsent() throws -> AnalyticsConsentState { try withState { $0.consent } }
    public func saveConsent(_ consent: AnalyticsConsentState) throws { try updateState { $0.consent = consent } }
    public func loadInstallationID() throws -> UUID? { try withState { $0.installationID } }
    public func saveInstallationID(_ id: UUID) throws { try updateState { $0.installationID = id } }
    public func deleteInstallationID() throws { try updateState { $0.installationID = nil } }
    public func loadLastDailyActiveDay() throws -> Date? { try withState { $0.lastDailyActiveDay } }
    public func saveLastDailyActiveDay(_ day: Date) throws { try updateState { $0.lastDailyActiveDay = day } }

    private func withState<T>(_ body: (State) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(readState())
    }

    private func updateState(_ body: (inout State) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var state = readState()
        try body(&state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: fileURL, options: [.atomic])
    }

    private func readState() -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }
}
