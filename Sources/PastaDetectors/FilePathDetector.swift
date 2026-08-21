import Foundation

public struct FilePathDetector {
    /// Classification of file types based on extension
    public enum FileType: String, Codable, CaseIterable {
        case image
        case video
        case audio
        case document
        case code
        case archive
        case data
        case executable
        case font
        case other
    }
    
    public struct Detection: Equatable {
        public var path: String
        public var exists: Bool
        public var filename: String
        public var fileExtension: String?
        public var fileType: FileType
        public var mimeType: String?
        public var confidence: Double

        public init(path: String, exists: Bool, filename: String, fileExtension: String?, fileType: FileType = .other, mimeType: String? = nil, confidence: Double) {
            self.path = path
            self.exists = exists
            self.filename = filename
            self.fileExtension = fileExtension
            self.fileType = fileType
            self.mimeType = mimeType
            self.confidence = confidence
        }
    }

    /// Existence checks hit the filesystem (`stat`), which is per-call cheap
    /// but adds up fast when someone copies a build log with hundreds of
    /// path-like tokens — and can block outright on unmounted network volumes.
    /// Only the first few unique candidates are checked; the rest are reported
    /// with `exists == false` and the lower confidence.
    public static let defaultExistenceCheckLimit = 20

    private let fileManager: FileManager
    private let existenceCheckLimit: Int

    public init(fileManager: FileManager = .default, existenceCheckLimit: Int = FilePathDetector.defaultExistenceCheckLimit) {
        self.fileManager = fileManager
        self.existenceCheckLimit = existenceCheckLimit
    }

    public func detect(in text: String) -> [Detection] {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(4)

        // Windows paths: C:\foo\bar.txt or C:/foo/bar.txt
        let windowsPattern = #"(?i)(?<![A-Z0-9_])([A-Z]:\\[^\s\"'<>|]+|[A-Z]:/[^\s\"'<>|]+)"#
        // Unix-ish paths: /foo/bar, ./foo, ../foo, ~/foo
        // Avoid matching the `/...` portion inside Windows `C:/...` paths.
        let unixPattern = #"(?<![A-Za-z]:)(?<![A-Za-z0-9_\-])((?:~|\.{1,2})?/(?:[^\s\"']+))"#

        candidates.append(contentsOf: match(pattern: windowsPattern, in: text, kind: .windows))
        candidates.append(contentsOf: match(pattern: unixPattern, in: text, kind: .unix))

        // De-dupe while preserving order, then stat only the first few unique
        // paths.
        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard seen.insert(candidate.path).inserted else { continue }

            let exists = out.count < existenceCheckLimit
                ? fileManager.fileExists(atPath: candidate.path)
                : false

            out.append(
                Detection(
                    path: candidate.path,
                    exists: exists,
                    filename: candidate.filename,
                    fileExtension: candidate.fileExtension,
                    fileType: candidate.fileType,
                    mimeType: candidate.mimeType,
                    // Higher confidence when the path is known to exist.
                    confidence: exists ? 0.9 : 0.7
                )
            )
        }

        return out
    }

    private enum Kind { case unix, windows }

    /// A path-shaped match before any filesystem access.
    private struct Candidate {
        let path: String
        let filename: String
        let fileExtension: String?
        let fileType: FileType
        let mimeType: String?
    }

    private static let regexCache: NSCache<NSString, NSRegularExpression> = {
        let cache = NSCache<NSString, NSRegularExpression>()
        cache.countLimit = 32
        return cache
    }()

    private static func cachedRegex(for pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        regexCache.setObject(compiled, forKey: key)
        return compiled
    }

    private func match(pattern: String, in text: String, kind: Kind) -> [Candidate] {
        guard let regex = Self.cachedRegex(for: pattern) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [Candidate] = []
        results.reserveCapacity(matches.count)

        for match in matches {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            var raw = String(text[r])

            // Trim common punctuation around paths.
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:()[]{}<>\"'"))
            if raw.isEmpty { continue }

            let normalizedPath: String
            switch kind {
            case .windows:
                // Normalize separators for existence checks.
                normalizedPath = raw.replacingOccurrences(of: "\\", with: "/")
            case .unix:
                normalizedPath = raw
            }

            let expanded = (normalizedPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)

            let filename = url.lastPathComponent
            let ext = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()

            results.append(
                Candidate(
                    path: expanded,
                    filename: filename,
                    fileExtension: ext,
                    fileType: Self.classifyFileType(extension: ext),
                    mimeType: Self.mimeType(for: ext)
                )
            )
        }

        return results
    }
    
    // MARK: - File Type Classification
    
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif",
        "svg", "ico", "icns", "raw", "cr2", "nef", "arw", "dng", "psd", "ai", "eps"
    ]
    
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpeg", "mpg",
        "3gp", "ogv", "ts", "mts", "m2ts"
    ]
    
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "aac", "flac", "ogg", "wma", "m4a", "aiff", "aif", "opus",
        "mid", "midi"
    ]
    
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
        "rtf", "txt", "md", "markdown", "tex", "pages", "numbers", "key",
        "epub", "mobi", "azw", "csv"
    ]
    
    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "jsx", "tsx", "java", "kt", "c", "cpp", "h", "hpp",
        "cs", "go", "rs", "rb", "php", "pl", "sh", "bash", "zsh", "fish",
        "html", "htm", "css", "scss", "sass", "less", "json", "xml", "yaml", "yml",
        "toml", "ini", "conf", "config", "sql", "graphql", "proto", "thrift",
        "r", "m", "mm", "scala", "clj", "cljs", "erl", "ex", "exs", "hs", "ml",
        "vue", "svelte", "astro"
    ]
    
    private static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "deb", "rpm"
    ]
    
    private static let dataExtensions: Set<String> = [
        "db", "sqlite", "sqlite3", "mdb", "accdb", "json", "xml", "plist", "dat"
    ]
    
    private static let executableExtensions: Set<String> = [
        "app", "exe", "msi", "bin", "command", "jar", "war", "apk", "ipa"
    ]
    
    private static let fontExtensions: Set<String> = [
        "ttf", "otf", "woff", "woff2", "eot"
    ]
    
    public static func classifyFileType(extension ext: String?) -> FileType {
        guard let ext = ext?.lowercased() else { return .other }
        
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if codeExtensions.contains(ext) { return .code }
        if archiveExtensions.contains(ext) { return .archive }
        if dataExtensions.contains(ext) { return .data }
        if executableExtensions.contains(ext) { return .executable }
        if fontExtensions.contains(ext) { return .font }
        
        return .other
    }
    
    public static func mimeType(for ext: String?) -> String? {
        guard let ext = ext?.lowercased() else { return nil }
        
        return Self.extensionToMimeType[ext]
    }
    
    private static let extensionToMimeType: [String: String] = [
        // Images
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "tiff": "image/tiff",
        "tif": "image/tiff",
        "webp": "image/webp",
        "heic": "image/heic",
        "heif": "image/heif",
        "svg": "image/svg+xml",
        "ico": "image/x-icon",
        "psd": "image/vnd.adobe.photoshop",
        
        // Video
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "avi": "video/x-msvideo",
        "mkv": "video/x-matroska",
        "webm": "video/webm",
        
        // Audio
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        
        // Documents
        "pdf": "application/pdf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "txt": "text/plain",
        "md": "text/markdown",
        "csv": "text/csv",
        
        // Code
        "html": "text/html",
        "css": "text/css",
        "js": "application/javascript",
        "json": "application/json",
        "xml": "application/xml",
        "yaml": "application/x-yaml",
        "yml": "application/x-yaml",
        
        // Archives
        "zip": "application/zip",
        "tar": "application/x-tar",
        "gz": "application/gzip",
        "7z": "application/x-7z-compressed",
        "rar": "application/vnd.rar",
        "dmg": "application/x-apple-diskimage",
    ]
}
