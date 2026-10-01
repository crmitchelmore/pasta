import Foundation

/// Keep the explicitly named development bundle away from installed history.
public enum PastaStorageLocation {
    public static var directoryName: String {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "com.pasta.clipboard.development" { return "Pasta Development" }
        #endif
        return ReleaseTrain.current.displayName
    }
}
