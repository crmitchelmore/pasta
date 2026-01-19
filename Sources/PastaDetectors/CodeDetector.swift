import Foundation
import PastaCore

public struct CodeDetector {
    public struct Detection: Equatable {
        public var code: String
        public var language: CodeLanguage
        public var confidence: Double

        public init(code: String, language: CodeLanguage, confidence: Double) {
            self.code = code
            self.language = language
            self.confidence = confidence
        }
    }

    public init() {}

    public func detect(in text: String) -> [Detection] {
        let candidates = extractCandidates(from: text)

        var seen = Set<String>()
        var out: [Detection] = []
        out.reserveCapacity(candidates.count)

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }

            let (language, confidence) = classify(trimmed)
            guard confidence >= 0.6 else { continue }
            out.append(Detection(code: trimmed, language: language, confidence: confidence))
        }

        return out
    }

    private func extractCandidates(from text: String) -> [String] {
        // Prefer fenced code blocks when present.
        // ```lang
        // code
        // ```
        let pattern = #"```([A-Za-z0-9_+-]+)?\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [text]
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard !matches.isEmpty else { return [text] }

        var blocks: [String] = []
        blocks.reserveCapacity(matches.count)
        for m in matches {
            guard m.numberOfRanges >= 3, let r = Range(m.range(at: 2), in: text) else { continue }
            blocks.append(String(text[r]))
        }
        return blocks.isEmpty ? [text] : blocks
    }

    private func classify(_ code: String) -> (CodeLanguage, Double) {
        // Strong type checks first.
        if let jsonConfidence = jsonConfidence(code) {
            return (.json, jsonConfidence)
        }
        if htmlConfidence(code) >= 0.9 { return (.html, htmlConfidence(code)) }
        if cssConfidence(code) >= 0.85 { return (.css, cssConfidence(code)) }

        // Require at least some signal that this is code-ish (unless it already matched above).
        if !looksLikeCode(code) {
            return (.unknown, 0.0)
        }

        let scores: [(CodeLanguage, Double)] = [
            (.swift, swiftScore(code)),
            (.python, pythonScore(code)),
            (.typeScript, typeScriptScore(code)),
            (.javaScript, javaScriptScore(code)),
            (.go, goScore(code)),
            (.rust, rustScore(code)),
            (.java, javaScore(code)),
            (.cCpp, cCppScore(code)),
            (.ruby, rubyScore(code)),
            (.sql, sqlScore(code)),
            (.yaml, yamlScore(code)),
            (.shell, shellScore(code))
        ]

        guard let best = scores.max(by: { $0.1 < $1.1 }) else {
            return (.unknown, 0.0)
        }

        return best
    }

    private func looksLikeCode(_ s: String) -> Bool {
        if s.contains("\n") { return true }
        let tokens = ["{", "}", ";", "=>", "==", "!=", "()", "[]", ":=", "::", "#include", "import "]
        return tokens.contains(where: { s.contains($0) })
    }

    private func jsonConfidence(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              obj is [Any] || obj is [String: Any]
        else {
            return nil
        }
        return 0.95
    }

    private func htmlConfidence(_ s: String) -> Double {
        let lower = s.lowercased()
        if lower.contains("<!doctype html") || lower.contains("<html") { return 0.95 }
        if lower.contains("<div") || lower.contains("<span") || lower.contains("</") { return 0.9 }
        return 0.0
    }

    private func cssConfidence(_ s: String) -> Double {
        // Heuristic: selector { property: value; }
        if s.contains("{") && s.contains(":") && s.contains(";") && s.contains("}") { return 0.9 }
        return 0.0
    }

    private func swiftScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("import SwiftUI") { score += 0.6 }
        if s.contains("struct ") || s.contains("enum ") || s.contains("protocol ") { score += 0.2 }
        if s.contains("func ") { score += 0.2 }
        if s.contains("let ") || s.contains("var ") { score += 0.1 }
        if s.contains(": ") && (s.contains("String") || s.contains("Int") || s.contains("Bool")) { score += 0.1 }
        return min(0.95, score)
    }

    private func pythonScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("def ") { score += 0.4 }
        if s.contains("import ") || s.contains("from ") { score += 0.2 }
        if s.contains("elif ") || s.contains("None") || s.contains("self") { score += 0.2 }
        if s.contains(":\n") { score += 0.2 }
        if s.contains("    ") { score += 0.1 } // indentation
        return min(0.95, score)
    }

    private func javaScriptScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("console.") { score += 0.2 }
        if s.contains("const ") || s.contains("let ") || s.contains("var ") { score += 0.2 }
        if s.contains("function ") { score += 0.2 }
        if s.contains("=>") { score += 0.2 }
        if s.contains("export ") || s.contains("import ") { score += 0.1 }
        return min(0.9, score)
    }

    private func typeScriptScore(_ s: String) -> Double {
        var score = javaScriptScore(s) * 0.8
        if s.contains("interface ") || s.contains("type ") { score += 0.4 }
        if s.contains(": number") || s.contains(": string") || s.contains(": boolean") { score += 0.3 }
        if s.contains(" as ") { score += 0.1 }
        return min(0.95, score)
    }

    private func goScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("package ") { score += 0.4 }
        if s.contains("func ") { score += 0.2 }
        if s.contains(":=") { score += 0.2 }
        if s.contains("import ") { score += 0.1 }
        if s.contains("fmt.") { score += 0.1 }
        return min(0.95, score)
    }

    private func rustScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("fn ") { score += 0.3 }
        if s.contains("let mut") || s.contains("impl ") { score += 0.2 }
        if s.contains("use ") { score += 0.1 }
        if s.contains("::") { score += 0.2 }
        if s.contains("println!") { score += 0.3 }
        return min(0.95, score)
    }

    private func javaScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("public class") { score += 0.5 }
        if s.contains("static void main") { score += 0.3 }
        if s.contains("System.out") { score += 0.2 }
        return min(0.95, score)
    }

    private func cCppScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("#include") { score += 0.6 }
        if s.contains("int main") { score += 0.2 }
        if s.contains("std::") { score += 0.2 }
        return min(0.95, score)
    }

    private func rubyScore(_ s: String) -> Double {
        var score = 0.0
        if s.contains("def ") { score += 0.3 }
        if s.contains("end") { score += 0.3 }
        if s.contains("puts ") { score += 0.2 }
        if s.contains("require ") { score += 0.1 }
        return min(0.9, score)
    }

    private func sqlScore(_ s: String) -> Double {
        let upper = s.uppercased()
        var score = 0.0
        if upper.contains("SELECT ") { score += 0.4 }
        if upper.contains("FROM ") { score += 0.2 }
        if upper.contains("WHERE ") { score += 0.2 }
        if upper.contains("INSERT ") || upper.contains("UPDATE ") || upper.contains("DELETE ") { score += 0.2 }
        if s.contains(";") { score += 0.1 }
        return min(0.95, score)
    }

    private func yamlScore(_ s: String) -> Double {
        // Minimal YAML heuristic: multiple "key: value" lines and indentation.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return 0.0 }

        var keyValueLines = 0
        var hasList = false
        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("-") { hasList = true }
            if l.contains(":") && !l.contains("{") && !l.contains("}") {
                keyValueLines += 1
            }
        }

        if keyValueLines >= 2 { return hasList ? 0.9 : 0.8 }
        return 0.0
    }

    private func shellScore(_ s: String) -> Double {
        var score = 0.0
        if s.hasPrefix("#!/") { score += 0.5 }
        if s.contains("export ") { score += 0.4 }
        if s.contains("set -e") { score += 0.2 }
        if s.contains("$(") || s.contains("`") { score += 0.1 }
        if s.contains("cd ") || s.contains("echo ") { score += 0.2 }
        return min(0.9, score)
    }
}
