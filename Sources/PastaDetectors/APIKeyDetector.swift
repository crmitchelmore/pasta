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
        
        init(_ provider: String, _ pattern: String, confidence: Double = 0.95) {
            self.provider = provider
            self.pattern = pattern
            self.confidence = confidence
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
        KeyPattern("AWS Secret Key", #"(?<![A-Za-z0-9/+])[A-Za-z0-9/+=]{40}(?![A-Za-z0-9/+=])"#, confidence: 0.70),
        
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
        
        // Heroku
        KeyPattern("Heroku API Key", #"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"#, confidence: 0.60),
        
        // DigitalOcean
        KeyPattern("DigitalOcean", #"dop_v1_[a-f0-9]{64}"#),
        KeyPattern("DigitalOcean", #"doo_v1_[a-f0-9]{64}"#),
        
        // Discord
        KeyPattern("Discord Bot", #"[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27}"#),
        KeyPattern("Discord Webhook", #"https://discord(?:app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"#),
        
        // Firebase
        KeyPattern("Firebase", #"AAAA[A-Za-z0-9_-]{7}:[A-Za-z0-9_-]{140}"#),
        
        // Datadog
        KeyPattern("Datadog API Key", #"[a-f0-9]{32}"#, confidence: 0.50),
        
        // Linear
        KeyPattern("Linear API Key", #"lin_api_[a-zA-Z0-9]{40}"#),
        
        // Vercel
        KeyPattern("Vercel Token", #"[A-Za-z0-9]{24}"#, confidence: 0.40),
        
        // Supabase
        KeyPattern("Supabase", #"sbp_[a-f0-9]{40}"#),
        
        // Replicate
        KeyPattern("Replicate", #"r8_[a-zA-Z0-9]{37}"#),
        
        // HuggingFace
        KeyPattern("HuggingFace", #"hf_[a-zA-Z0-9]{34}"#),
        
        // Cohere
        KeyPattern("Cohere", #"[a-zA-Z0-9]{40}"#, confidence: 0.35),
        
        // Mapbox
        KeyPattern("Mapbox", #"pk\.[a-zA-Z0-9]{60,}"#),
        KeyPattern("Mapbox Secret", #"sk\.[a-zA-Z0-9]{60,}"#),
        
        // Algolia
        KeyPattern("Algolia", #"[a-f0-9]{32}"#, confidence: 0.45),
        
        // PlanetScale
        KeyPattern("PlanetScale", #"pscale_tkn_[a-zA-Z0-9_]+"#),
        
        // Deepgram
        KeyPattern("Deepgram", #"[a-f0-9]{40}"#, confidence: 0.50),
        
        // Rev.ai
        KeyPattern("Rev.ai", #"[a-zA-Z0-9]{32,}"#, confidence: 0.40),
        
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
