import PastaCore

/// The one filter the main panel applies on top of the search query. The
/// sidebar edits it directly; every other reader derives its narrower view
/// (content type, domain, source app, pinned) from the properties below.
public enum FilterSelection: Hashable {
    case all
    case pinned
    case type(ContentType)
    case domain(String)
    case sourceApp(String)

    /// Content type narrowed to; a domain filter implies `.url`.
    public var contentType: ContentType? {
        switch self {
        case .type(let type): return type
        case .domain: return .url
        case .all, .pinned, .sourceApp: return nil
        }
    }

    /// Specific URL domain, or nil for "All Domains" (`.domain("")`) and
    /// every non-domain selection.
    public var urlDomain: String? {
        if case .domain(let domain) = self, !domain.isEmpty { return domain }
        return nil
    }

    /// Source-app identifier filter, or nil when not filtering by app.
    public var sourceApp: String? {
        if case .sourceApp(let app) = self { return app }
        return nil
    }

    /// Whether only pinned entries should be shown.
    public var isPinnedOnly: Bool {
        self == .pinned
    }
}
