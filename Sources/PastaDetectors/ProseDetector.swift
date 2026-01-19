import Foundation

public struct ProseDetector {
    public struct Detection: Equatable {
        public var text: String
        public var wordCount: Int
        public var estimatedReadingTimeSeconds: Int
        public var confidence: Double

        public init(text: String, wordCount: Int, estimatedReadingTimeSeconds: Int, confidence: Double) {
            self.text = text
            self.wordCount = wordCount
            self.estimatedReadingTimeSeconds = estimatedReadingTimeSeconds
            self.confidence = confidence
        }
    }

    public init() {}

    /// Attempts to classify a string as natural-language prose (as opposed to code or structured data).
    public func detect(in text: String) -> Detection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return nil }

        if containsCodeSignals(trimmed) { return nil }
        if looksStructured(trimmed) { return nil }

        let words = wordCount(in: trimmed)
        guard words >= 12 else { return nil }

        let sentenceCount = trimmed.reduce(into: 0) { acc, c in
            if c == "." || c == "!" || c == "?" { acc += 1 }
        }

        // Allow long prose without explicit punctuation (e.g. copied paragraph fragments), but require more words.
        guard sentenceCount >= 1 || words >= 30 else { return nil }

        let readingSeconds = Int(ceil((Double(words) / 200.0) * 60.0))

        var confidence = 0.55
        confidence += min(0.25, Double(words) / 80.0) // more words => more likely prose
        confidence += min(0.15, Double(sentenceCount) * 0.07)

        // Penalize if it has lots of non-letter symbols.
        let symbolRatio = nonLetterSymbolRatio(in: trimmed)
        confidence -= min(0.3, symbolRatio * 0.6)

        confidence = min(0.95, max(0.0, confidence))
        guard confidence >= 0.6 else { return nil }

        return Detection(text: trimmed, wordCount: words, estimatedReadingTimeSeconds: readingSeconds, confidence: confidence)
    }

    private func containsCodeSignals(_ s: String) -> Bool {
        let lower = s.lowercased()
        let tokens = [
            "```",
            "{", "}", ";",
            "#include", "import ", "func ", "struct ", "class ", "let ", "var ",
            "=>", "->", "::", ":=",
            "select ", "from ", "where ",
            "<html", "</"
        ]
        if tokens.contains(where: { lower.contains($0) }) { return true }

        // Many braces/semicolons strongly suggest code.
        let strongChars: Set<Character> = ["{", "}", ";"]
        let strongCount = s.reduce(into: 0) { acc, c in
            if strongChars.contains(c) { acc += 1 }
        }
        return strongCount >= 2
    }

    private func looksStructured(_ s: String) -> Bool {
        let lines = s.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return false }

        var structured = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }

            // KEY=value (env), key: value (YAML-ish)
            if let eq = line.firstIndex(of: "="), eq != line.startIndex {
                structured += 1
                continue
            }
            if let colon = line.firstIndex(of: ":"), colon != line.startIndex {
                // Avoid treating normal sentences with ':' as structured.
                let before = line[..<colon]
                if before.range(of: "\\s", options: .regularExpression) == nil {
                    structured += 1
                    continue
                }
            }
        }

        // If most lines are structured, treat as non-prose.
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard nonEmpty > 0 else { return false }
        return structured >= 2 && (Double(structured) / Double(nonEmpty)) >= 0.5
    }

    private func wordCount(in s: String) -> Int {
        let pattern = #"\b[\p{L}\p{N}]+(?:'[\p{L}\p{N}]+)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return 0 }
        let nsRange = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.numberOfMatches(in: s, options: [], range: nsRange)
    }

    private func nonLetterSymbolRatio(in s: String) -> Double {
        guard !s.isEmpty else { return 0.0 }
        var nonLetterOrSpace = 0
        for u in s.unicodeScalars {
            if CharacterSet.letters.contains(u) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(u) { continue }
            nonLetterOrSpace += 1
        }
        return Double(nonLetterOrSpace) / Double(s.unicodeScalars.count)
    }
}
