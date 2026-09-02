import Foundation
import GRDB

/// Bitmask of the extractable content types present in an entry's metadata.
///
/// Computed once when an entry is created (or its metadata changes) and
/// persisted in the `contentTypeMask` column, so per-type counts and filters
/// over the whole history are a single integer test per entry instead of a
/// JSON parse or substring scan of the metadata string.
///
/// Bit positions are part of the on-disk format: never renumber an existing
/// case, only append.
public struct ContentTypeMask: OptionSet, Hashable, Sendable, Codable, DatabaseValueConvertible {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let email = ContentTypeMask(rawValue: 1 << 0)
    public static let url = ContentTypeMask(rawValue: 1 << 1)
    public static let phoneNumber = ContentTypeMask(rawValue: 1 << 2)
    public static let ipAddress = ContentTypeMask(rawValue: 1 << 3)
    public static let uuid = ContentTypeMask(rawValue: 1 << 4)
    public static let hash = ContentTypeMask(rawValue: 1 << 5)
    public static let apiKey = ContentTypeMask(rawValue: 1 << 6)
    public static let jwt = ContentTypeMask(rawValue: 1 << 7)
    public static let envVar = ContentTypeMask(rawValue: 1 << 8)
    public static let envVarBlock = ContentTypeMask(rawValue: 1 << 9)
    public static let filePath = ContentTypeMask(rawValue: 1 << 10)
    public static let shellCommand = ContentTypeMask(rawValue: 1 << 11)

    /// The bit for `type`, or `nil` when the type is not one that metadata can
    /// carry (e.g. `.text`, `.image`).
    public init?(_ type: ContentType) {
        switch type {
        case .email: self = .email
        case .url: self = .url
        case .phoneNumber: self = .phoneNumber
        case .ipAddress: self = .ipAddress
        case .uuid: self = .uuid
        case .hash: self = .hash
        case .apiKey: self = .apiKey
        case .jwt: self = .jwt
        case .envVar: self = .envVar
        case .envVarBlock: self = .envVarBlock
        case .filePath: self = .filePath
        case .shellCommand: self = .shellCommand
        default: return nil
        }
    }

    /// Whether metadata items of `type` are present.
    public func contains(_ type: ContentType) -> Bool {
        guard let bit = ContentTypeMask(type) else { return false }
        return contains(bit)
    }
}
