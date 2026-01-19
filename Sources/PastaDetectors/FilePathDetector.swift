import Foundation

public struct FilePathDetector {
    public struct Detection: Equatable {
        public var path: String
        public var exists: Bool
        public var filename: String
        public var fileExtension: String?
        public var confidence: Double

        public init(path: String, exists: Bool, filename: String, fileExtension: String?, confidence: Double) {
            self.path = path
            self.exists = exists
            self.filename = filename
            self.fileExtension = fileExtension
            self.confidence = confidence
        }
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func detect(in text: String) -> [Detection] {
        var detections: [Detection] = []
        detections.reserveCapacity(4)

        // Windows paths: C:\foo\bar.txt or C:/foo/bar.txt
        let windowsPattern = #"(?i)(?<![A-Z0-9_])([A-Z]:\\[^\s\"'<>|]+|[A-Z]:/[^\s\"'<>|]+)"#
        // Unix-ish paths: /foo/bar, ./foo, ../foo, ~/foo
        // Avoid matching the `/...` portion inside Windows `C:/...` paths.
        let unixPattern = #"(?<![A-Za-z]:)(?<![A-Za-z0-9_\-])((?:~|\.{1,2})?/(?:[^\s\"']+))"#

        detections.append(contentsOf: match(pattern: windowsPattern, in: text, kind: .windows))
        detections.append(contentsOf: match(pattern: unixPattern, in: text, kind: .unix))

        // De-dupe while preserving order.
        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(detections.count)
        for d in detections {
            let key = d.path
            guard seen.insert(key).inserted else { continue }
            out.append(d)
        }

        return out
    }

    private enum Kind { case unix, windows }

    private func match(pattern: String, in text: String, kind: Kind) -> [Detection] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var results: [Detection] = []
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

            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: expanded, isDirectory: &isDir)

            let filename = url.lastPathComponent
            let ext = url.pathExtension.isEmpty ? nil : url.pathExtension

            // Higher confidence when the path exists.
            let confidence: Double = exists ? 0.9 : 0.7

            results.append(
                Detection(
                    path: expanded,
                    exists: exists,
                    filename: filename,
                    fileExtension: ext,
                    confidence: confidence
                )
            )
        }

        return results
    }
}
