import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Builds the text Pasta embeds for an entry.
///
/// Raw clipboard text is often opaque (a serial number, an order code), so
/// the embedded document also describes what the text *looks like* and where
/// it was copied from. A query such as "apple watch serial number" then lands
/// near a bare `F4GXK2J1HG7Q` copied from Continuity even though no word in
/// the query appears in the content.
public enum SemanticDocument {
    /// Embedding models handle ~8k tokens; the head of an entry carries its meaning.
    public static let maxContentCharacters = 2_000

    public struct Input: Sendable, Equatable {
        public var content: String
        public var contentType: ContentType
        public var sourceApp: String?

        public init(content: String, contentType: ContentType, sourceApp: String?) {
            self.content = content
            self.contentType = contentType
            self.sourceApp = sourceApp
        }
    }

    /// The text to embed, or `nil` when the entry has nothing meaningful to embed.
    public static func text(for input: Input, appName: (String) -> String? = SourceAppNameResolver.displayName) -> String? {
        if input.contentType == .image || input.contentType == .screenshot { return nil }
        let content = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        var header = description(of: input.contentType, content: content)
        if [.text, .unknown, .prose].contains(input.contentType), let hint = shapeHint(for: content) {
            header += ". \(hint)"
        }
        if let raw = input.sourceApp, let source = sourceDescription(raw, appName: appName) { header += ". \(source)" }

        let body = content.count > maxContentCharacters ? String(content.prefix(maxContentCharacters)) : content
        return "\(header).\n\(body)"
    }

    static func description(of type: ContentType, content: String) -> String {
        switch type {
        case .text, .unknown: return "Text"
        case .prose: return "Written text"
        case .email: return "Email address"
        case .phoneNumber: return "Phone number"
        case .ipAddress: return "IP address"
        case .uuid: return "UUID identifier"
        case .hash: return "Hash or checksum"
        case .jwt: return "JSON Web Token"
        case .apiKey: return "API key or secret token"
        case .envVar: return "Environment variable"
        case .envVarBlock: return "Environment variables (.env)"
        case .filePath: return "File path"
        case .url:
            if let host = URL(string: content)?.host?.replacingOccurrences(of: "www.", with: "") {
                return "Web link to \(host)"
            }
            return "Web link"
        case .code: return "Source code"
        case .shellCommand: return "Terminal command"
        case .color: return "Colour value"
        case .macAddress: return "MAC address (network hardware address)"
        case .creditCard: return "Payment card number"
        case .iban: return "Bank account number (IBAN)"
        case .image, .screenshot: return "Image"
        }
    }

    /// Describes short, single-token content whose meaning is not in its words.
    static func shapeHint(for content: String) -> String? {
        guard content.count <= 64, !content.contains(where: \.isWhitespace) else { return nil }
        let letters = content.filter(\.isLetter).count
        let digits = content.filter(\.isNumber).count
        let alphanumerics = letters + digits
        let separators = content.filter { $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" }.count
        guard alphanumerics + separators == content.count, digits > 0 else { return nil }

        if letters == 0 {
            switch digits {
            case 4...8: return "Short number; could be a PIN, verification code or one-time passcode"
            case 9...24: return "Long number; could be an account, order, tracking, reference or IMEI number"
            default: return nil
            }
        }
        let isUppercase = content.filter(\.isLetter).allSatisfy(\.isUppercase)
        if separators > 0, content.split(whereSeparator: { "-_./".contains($0) }).count >= 3, alphanumerics >= 8 {
            return "Grouped code; could be a licence or product key, serial number or reference"
        }
        guard separators == 0, (6...40).contains(alphanumerics) else { return nil }
        if isUppercase {
            return "Code of \(alphanumerics) uppercase letters and digits; could be a serial number, product key, booking reference, order or tracking number"
        }
        return "Code of mixed letters and digits; could be a password, confirmation code, voucher or reference"
    }

    static func sourceDescription(_ sourceApp: String, appName: (String) -> String?) -> String? {
        let trimmed = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "Unknown" else { return nil }
        if trimmed == "Continuity" { return "Copied from another Apple device (iPhone, iPad or Mac) via Continuity" }
        return "Copied from \(appName(trimmed) ?? trimmed)"
    }
}

/// Resolves bundle identifiers to app names without depending on PastaUI.
public enum SourceAppNameResolver {
    private static let cache = NSCache<NSString, NSString>()

    public static func displayName(for sourceApp: String) -> String? {
        let key = sourceApp as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let resolved = resolve(sourceApp)
        cache.setObject(resolved as NSString, forKey: key)
        return resolved
    }

    private static func resolve(_ sourceApp: String) -> String {
        let parts = sourceApp.split(separator: ".")
        guard parts.count > 1, !sourceApp.contains(" ") else { return sourceApp }
#if canImport(AppKit)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceApp) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
#endif
        let candidate = parts.reversed().first { $0.contains(where: \.isLetter) } ?? parts.last!
        return String(candidate).prefix(1).uppercased() + candidate.dropFirst()
    }
}
