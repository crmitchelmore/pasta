import PastaCore

public enum FilterSelection: Hashable {
    case all
    case pinned
    case type(ContentType)
    case domain(String)
    case sourceApp(String)
}
