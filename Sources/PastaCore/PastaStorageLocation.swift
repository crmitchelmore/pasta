import Foundation

/// Keep the explicitly named development bundle away from installed history.
public enum PastaStorageLocation {
    public static var directoryName: String {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "com.pasta.clipboard.development" { return "Pasta Development" }
        #endif
        #if os(iOS)
        // TestFlight Alpha and the App Store build install over each other.
        return ReleaseTrain.stable.displayName
        #else
        return ReleaseTrain.current.displayName
        #endif
    }
}
