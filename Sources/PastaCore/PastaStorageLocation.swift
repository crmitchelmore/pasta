import Foundation

/// Keep the explicitly named development bundle away from installed history.
enum PastaStorageLocation {
    static var directoryName: String {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "com.pasta.clipboard.development" { return "Pasta Development" }
        #endif
        return "Pasta"
    }
}
