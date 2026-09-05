import Foundation

/// The legacy fetch checkpoint did not prove that downloaded records reached
/// the database. Start once from a new key to recover those skipped records.
/// Subsequent launches reuse only checkpoints from the durable apply path.
enum SyncChangeTokenStore {
    private static let key = "com.pasta.sync.appliedChangeToken.v1"

    static func load(from defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: key)
    }

    static func save(_ token: Data, to defaults: UserDefaults = .standard) {
        defaults.set(token, forKey: key)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
