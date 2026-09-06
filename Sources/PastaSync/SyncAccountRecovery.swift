import CloudKit
import Foundation

/// Rechecks the account on every attempt, including after an offline launch.
/// The only injected boundaries are account lookup and the sync operations;
/// callers retain their existing durable upload and pull transactions.
@MainActor
public final class SyncAccountRecovery {
    public enum Availability: Equatable {
        case notChecked, available, noAccount, restricted, temporarilyUnavailable, couldNotDetermine
        case unavailableBuild, disabled

        public var label: String {
            switch self {
            case .disabled: return "Off"
            case .notChecked: return "Not Checked"
            case .available: return "Connected"
            case .noAccount: return "Not Signed In"
            case .restricted: return "Restricted"
            case .temporarilyUnavailable: return "Temporarily Unavailable"
            case .couldNotDetermine: return "Unable to Check"
            case .unavailableBuild: return "Unavailable in This Build"
            }
        }

        public var guidance: String? {
            switch self {
            case .disabled: return "Turn on Enable iCloud Sync above to sync with your Mac."
            case .notChecked, .available: return nil
            case .noAccount: return "Sign in to iCloud in iPhone Settings, then tap Sync Now."
            case .restricted: return "iCloud access is restricted. Check the account restrictions in iPhone Settings."
            case .temporarilyUnavailable, .couldNotDetermine:
                return "iCloud could not be reached. Check your connection and tap Sync Now to retry."
            case .unavailableBuild:
                return "This build cannot access iCloud. Install the latest signed Pasta update."
            }
        }
    }

    public private(set) var availability: Availability = .notChecked
    public private(set) var errorMessage: String?
    public private(set) var isRunning = false

    public init() {}

    public func run(
        checkAccount: () async throws -> CKAccountStatus,
        prepare: () async throws -> Void,
        sync: () async throws -> Void
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        errorMessage = nil
        // Never leave a previous "Connected" result behind after lookup fails.
        availability = .couldNotDetermine
        do {
            try Task.checkCancellation()
            let account = try await checkAccount()
            switch account {
            case .available: availability = .available
            case .noAccount: availability = .noAccount
            case .restricted: availability = .restricted
            case .temporarilyUnavailable: availability = .temporarilyUnavailable
            case .couldNotDetermine: availability = .couldNotDetermine
            @unknown default: availability = .couldNotDetermine
            }
            guard availability == .available else { return }
            try Task.checkCancellation()
            try await prepare()
            try Task.checkCancellation()
            try await sync()
        } catch is CancellationError {
            // A later activation performs a new lookup; cancellation is not a
            // successful sync and must never update the persisted checkpoint.
        } catch let error as SyncManager.AccountError {
            switch error {
            case .syncDisabled: availability = .disabled
            case .missingEntitlement: availability = .unavailableBuild
            }
            errorMessage = availability.guidance
        } catch {
            if let cloudError = error as? CKError, cloudError.code == .notAuthenticated {
                availability = .noAccount
            }
            // CloudKit descriptions can contain record IDs and internal details.
            // Keep the recovery action useful without exposing those in Settings.
            switch (error as? CKError)?.code {
            case .networkUnavailable, .networkFailure:
                errorMessage = "Sync could not connect. Check your internet connection, then tap Sync Now."
            case .notAuthenticated:
                errorMessage = availability.guidance
            case .quotaExceeded:
                errorMessage = "Your iCloud storage is full. Free up space in iPhone Settings, then tap Sync Now."
            case .serviceUnavailable, .requestRateLimited, .zoneBusy:
                errorMessage = "iCloud is temporarily busy. Wait a moment, then tap Sync Now."
            default:
                errorMessage = "Sync could not finish. Your local history is safe. Tap Sync Now to retry."
            }
        }
    }
}
