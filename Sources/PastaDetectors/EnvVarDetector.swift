import Foundation

public struct EnvVarDetector {
    public struct Detection: Equatable {
        public var key: String
        public var value: String
        public var isExported: Bool
        public var confidence: Double

        public init(key: String, value: String, isExported: Bool, confidence: Double) {
            self.key = key
            self.value = value
            self.isExported = isExported
            self.confidence = confidence
        }
    }

    public struct Output: Equatable {
        public var detections: [Detection]
        public var isBlock: Bool

        public init(detections: [Detection], isBlock: Bool) {
            self.detections = detections
            self.isBlock = isBlock
        }
    }

    public init() {}

    /// Detects environment variable assignments in `.env`-style formats.
    ///
    /// Supported line shapes:
    /// - `KEY=value`
    /// - `export KEY=value`
    /// - `KEY="value"` / `KEY='value'`
    public func detect(in text: String) -> Output? {
        let lines = text.split(whereSeparator: \.isNewline)

        var detections: [Detection] = []
        detections.reserveCapacity(lines.count)

        var nonEmptyNonCommentLineCount = 0

        for raw in lines {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }

            nonEmptyNonCommentLineCount += 1

            if let detection = parseLine(line) {
                detections.append(detection)
            }
        }

        guard !detections.isEmpty else { return nil }

        let isBlock = detections.count >= 2

        // Confidence is highest when the text is essentially an env block (i.e. every non-comment line parsed).
        let confidence: Double = (detections.count == nonEmptyNonCommentLineCount) ? 0.95 : 0.75
        let adjusted = detections.map { Detection(key: $0.key, value: $0.value, isExported: $0.isExported, confidence: confidence) }

        return Output(detections: adjusted, isBlock: isBlock)
    }

    private func parseLine(_ line: String) -> Detection? {
        var working = line
        var isExported = false

        if working.hasPrefix("export ") {
            isExported = true
            working = String(working.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        }

        guard let eqIndex = working.firstIndex(of: "=") else { return nil }

        let keyPart = working[..<eqIndex].trimmingCharacters(in: .whitespaces)
        let valuePart = working[working.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

        guard isValidKey(keyPart) else { return nil }
        let value = parseValue(String(valuePart))

        return Detection(key: keyPart, value: value, isExported: isExported, confidence: 0.95)
    }

    private func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        func isAlphaOrUnderscore(_ u: UnicodeScalar) -> Bool {
            (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) || u == "_"
        }
        func isAlnumOrUnderscore(_ u: UnicodeScalar) -> Bool {
            isAlphaOrUnderscore(u) || (u.value >= 48 && u.value <= 57)
        }

        guard isAlphaOrUnderscore(first) else { return false }
        return key.unicodeScalars.allSatisfy(isAlnumOrUnderscore)
    }

    private func parseValue(_ value: String) -> String {
        guard !value.isEmpty else { return "" }

        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            let inner = String(value.dropFirst().dropLast())
            return unescapeDoubleQuoted(inner)
        }

        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    private func unescapeDoubleQuoted(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)

        var i = value.startIndex
        while i < value.endIndex {
            let c = value[i]
            if c == "\\", value.index(after: i) < value.endIndex {
                let nextIndex = value.index(after: i)
                let next = value[nextIndex]
                switch next {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                default:
                    out.append(next)
                }
                i = value.index(after: nextIndex)
                continue
            }

            out.append(c)
            i = value.index(after: i)
        }

        return out
    }
}
