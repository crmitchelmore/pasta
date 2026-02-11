import Foundation

/// Detects API keys from well-known providers based on their characteristic patterns.
public struct APIKeyDetector {
    public struct Detection: Equatable {
        public var key: String
        public var provider: String
        public var confidence: Double
        /// Whether this looks like a live key vs test/example key
        public var isLikelyLive: Bool
        
        public init(key: String, provider: String, confidence: Double, isLikelyLive: Bool) {
            self.key = key
            self.provider = provider
            self.confidence = confidence
            self.isLikelyLive = isLikelyLive
        }
    }
    
    /// Known API key patterns with their providers
    private struct KeyPattern {
        let provider: String
        let pattern: String
        let confidence: Double
        /// When true, the pattern has a distinctive prefix (e.g. `sk-`, `ghp_`) so
        /// boundary enforcement is less critical. When false, a post-match boundary
        /// check is applied to reject matches embedded in longer alphanumeric runs.
        let hasDistinctivePrefix: Bool
        
        init(_ provider: String, _ pattern: String, confidence: Double = 0.95, hasDistinctivePrefix: Bool = true) {
            self.provider = provider
            self.pattern = pattern
            self.confidence = confidence
            self.hasDistinctivePrefix = hasDistinctivePrefix
        }
    }
    
    private let patterns: [KeyPattern] = [
        // OpenAI
        KeyPattern("OpenAI", #"sk-[a-zA-Z0-9]{20}T3BlbkFJ[a-zA-Z0-9]{20}"#),
        KeyPattern("OpenAI", #"sk-proj-[a-zA-Z0-9\-_]{80,180}"#),
        KeyPattern("OpenAI", #"sk-[a-zA-Z0-9]{48}"#, confidence: 0.85),
        
        // Anthropic
        KeyPattern("Anthropic", #"sk-ant-api03-[a-zA-Z0-9\-_]{93}"#),
        KeyPattern("Anthropic", #"sk-ant-[a-zA-Z0-9\-_]{40,100}"#, confidence: 0.90),
        
        // Google Cloud / Gemini
        KeyPattern("Google Cloud", #"AIza[0-9A-Za-z\-_]{35}"#),
        
        // AWS
        KeyPattern("AWS Access Key", #"AKIA[0-9A-Z]{16}"#),
        KeyPattern("AWS Secret Key", #"(?<![A-Za-z0-9/+])[A-Za-z0-9/+=]{40}(?![A-Za-z0-9/+=])"#, confidence: 0.70, hasDistinctivePrefix: false),
        
        // GitHub
        KeyPattern("GitHub PAT", #"ghp_[a-zA-Z0-9]{36}"#),
        KeyPattern("GitHub PAT (fine-grained)", #"github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}"#),
        KeyPattern("GitHub OAuth", #"gho_[a-zA-Z0-9]{36}"#),
        KeyPattern("GitHub App", #"ghu_[a-zA-Z0-9]{36}"#),
        KeyPattern("GitHub Refresh", #"ghr_[a-zA-Z0-9]{36}"#),
        
        // Stripe
        KeyPattern("Stripe Secret", #"sk_live_[a-zA-Z0-9]{24,}"#),
        KeyPattern("Stripe Test", #"sk_test_[a-zA-Z0-9]{24,}"#),
        KeyPattern("Stripe Publishable", #"pk_live_[a-zA-Z0-9]{24,}"#),
        KeyPattern("Stripe Restricted", #"rk_live_[a-zA-Z0-9]{24,}"#),
        
        // Slack
        KeyPattern("Slack Bot", #"xoxb-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}"#),
        KeyPattern("Slack User", #"xoxp-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}"#),
        KeyPattern("Slack App", #"xapp-[0-9]-[A-Z0-9]+-[0-9]+-[a-zA-Z0-9]+"#),
        KeyPattern("Slack Webhook", #"https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[a-zA-Z0-9]+"#),
        
        // Twilio
        KeyPattern("Twilio API Key", #"SK[a-f0-9]{32}"#),
        KeyPattern("Twilio Account SID", #"AC[a-f0-9]{32}"#),
        
        // SendGrid
        KeyPattern("SendGrid", #"SG\.[a-zA-Z0-9\-_]{22}\.[a-zA-Z0-9\-_]{43}"#),
        
        // Mailgun
        KeyPattern("Mailgun", #"key-[a-f0-9]{32}"#),
        
        // npm
        KeyPattern("npm Token", #"npm_[a-zA-Z0-9]{36}"#),
        
        // PyPI
        KeyPattern("PyPI Token", #"pypi-[a-zA-Z0-9\-_]{100,}"#),
        
        // DigitalOcean
        KeyPattern("DigitalOcean", #"dop_v1_[a-f0-9]{64}"#),
        KeyPattern("DigitalOcean", #"doo_v1_[a-f0-9]{64}"#),
        
        // Discord
        KeyPattern("Discord Bot", #"[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27}"#),
        KeyPattern("Discord Webhook", #"https://discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"#),
        
        // Firebase
        KeyPattern("Firebase", #"AAAA[A-Za-z0-9_-]{7}:[A-Za-z0-9_-]{140}"#),
        
        // Linear
        KeyPattern("Linear API Key", #"lin_api_[a-zA-Z0-9]{40}"#),
        
        // Supabase
        KeyPattern("Supabase", #"sbp_[a-f0-9]{40}"#),
        
        // Replicate
        KeyPattern("Replicate", #"r8_[a-zA-Z0-9]{37}"#),
        
        // HuggingFace
        KeyPattern("HuggingFace", #"hf_[a-zA-Z0-9]{34}"#),
        
        // Mapbox
        KeyPattern("Mapbox", #"pk\.[a-zA-Z0-9]{60,}"#),
        KeyPattern("Mapbox Secret", #"sk\.[a-zA-Z0-9]{60,}"#),
        
        // PlanetScale
        KeyPattern("PlanetScale", #"pscale_tkn_[a-zA-Z0-9_]+"#),
        
        // Generic patterns (lower confidence)
        KeyPattern("Generic API Key", #"(?i)api[_-]?key['":\s=]+['"]?([a-zA-Z0-9\-_]{20,})['"]?"#, confidence: 0.65),
        KeyPattern("Generic Secret", #"(?i)secret[_-]?key['":\s=]+['"]?([a-zA-Z0-9\-_]{20,})['"]?"#, confidence: 0.65),
        KeyPattern("Generic Token", #"(?i)access[_-]?token['":\s=]+['"]?([a-zA-Z0-9\-_]{20,})['"]?"#, confidence: 0.65),
        KeyPattern("Bearer Token", #"Bearer\s+[a-zA-Z0-9\-_\.]{20,}"#, confidence: 0.80),
    ]
    
    public init() {}
    
    public func detect(in text: String) -> [Detection] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return [] }
        
        var detections: [Detection] = []
        var seenKeys = Set<String>()
        
        for keyPattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: keyPattern.pattern, options: []) else {
                continue
            }
            
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let matches = regex.matches(in: trimmed, options: [], range: range)
            
            for match in matches {
                guard let matchRange = Range(match.range, in: trimmed) else { continue }
                let key = String(trimmed[matchRange])
                
                // Skip if we've already found this key
                guard seenKeys.insert(key).inserted else { continue }
                
                // For patterns without a distinctive prefix, verify the match is
                // bounded by whitespace, start/end of string, or common delimiters
                // (quotes, equals, colons, commas, brackets). This prevents matching
                // substrings inside longer tokens like JWTs or base64-encoded content.
                if !keyPattern.hasDistinctivePrefix && !hasBoundary(in: trimmed, matchRange: matchRange) {
                    continue
                }
                
                // Skip obvious test/example keys
                let isLikelyLive = !isTestOrExampleKey(key)
                
                // Adjust confidence for test keys
                let adjustedConfidence = isLikelyLive ? keyPattern.confidence : keyPattern.confidence * 0.5
                
                detections.append(Detection(
                    key: key,
                    provider: keyPattern.provider,
                    confidence: adjustedConfidence,
                    isLikelyLive: isLikelyLive
                ))
            }
        }
        
        // Sort by confidence descending, return highest confidence matches
        detections.sort { $0.confidence > $1.confidence }
        
        // Filter out low-confidence generic matches if we have specific provider matches
        if let topConfidence = detections.first?.confidence, topConfidence >= 0.85 {
            detections = detections.filter { $0.confidence >= 0.60 || $0.provider == detections.first?.provider }
        }
        
        return detections
    }
    
    /// Checks that a match is bounded by whitespace, start/end, or common delimiters.
    /// Returns false if the match is embedded inside a longer alphanumeric/base64 sequence.
    private func hasBoundary(in text: String, matchRange: Range<String.Index>) -> Bool {
        let boundaryChars: Set<Character> = [" ", "\t", "\n", "\r", "\"", "'", "=", ":", ",", ";", "(", ")", "[", "]", "{", "}", "<", ">", "|", "`"]
        
        // Check leading boundary
        if matchRange.lowerBound != text.startIndex {
            let preceding = text[text.index(before: matchRange.lowerBound)]
            if !boundaryChars.contains(preceding) && !preceding.isNewline {
                return false
            }
        }
        
        // Check trailing boundary
        if matchRange.upperBound != text.endIndex {
            let following = text[matchRange.upperBound]
            if !boundaryChars.contains(following) && !following.isNewline {
                return false
            }
        }
        
        return true
    }
    
    /// Check if a key looks like a test/example/placeholder
    private func isTestOrExampleKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        
        let testIndicators = [
            "test", "example", "sample", "demo", "fake", "dummy",
            "placeholder", "xxx", "your_", "your-", "insert", "replace",
            "todo", "fixme", "changeme", "secret_here", "key_here",
            "0000000", "1111111", "aaaaaaa", "abcdef"
        ]
        
        for indicator in testIndicators {
            if lowered.contains(indicator) {
                return true
            }
        }
        
        // Check for obvious patterns like all same char
        let uniqueChars = Set(key.filter { $0.isLetter || $0.isNumber })
        if uniqueChars.count < 4 && key.count > 10 {
            return true
        }
        
        return false
    }
    
    /// Check if the entire text is likely just an API key (vs containing one)
    public func isEntirelyAPIKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let detections = detect(in: trimmed)
        
        guard let first = detections.first else { return false }
        
        // If the detected key is most of the text, it's entirely an API key
        let keyLength = first.key.count
        let textLength = trimmed.count
        
        return Double(keyLength) / Double(textLength) > 0.8 && first.confidence >= 0.70
    }
}
