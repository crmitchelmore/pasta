import PastaCore

public enum FilterSelection: Hashable {
    case all
    case type(ContentType)
    case domain(String)
    case sourceApp(String)
}
