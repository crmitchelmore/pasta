import Foundation

public struct JWTDetector {
    public struct Claims: Equatable {
        public var exp: Date?
        public var iat: Date?
        public var sub: String?
        public var iss: String?

        public init(exp: Date? = nil, iat: Date? = nil, sub: String? = nil, iss: String? = nil) {
            self.exp = exp
            self.iat = iat
            self.sub = sub
            self.iss = iss
        }
    }

    public struct Detection: Equatable {
        public var token: String
        public var confidence: Double
        public var headerJSON: String
        public var payloadJSON: String
        public var claims: Claims
        /// Nil when no `exp` claim exists.
        public var isExpired: Bool?

        public init(
            token: String,
            confidence: Double,
            headerJSON: String,
            payloadJSON: String,
            claims: Claims,
            isExpired: Bool?
        ) {
            self.token = token
            self.confidence = confidence
            self.headerJSON = headerJSON
            self.payloadJSON = payloadJSON
            self.claims = claims
            self.isExpired = isExpired
        }
    }

    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func detect(in text: String) -> [Detection] {
        // JWT (JWS) shape: header.payload.signature; each segment is base64url.
        let pattern = #"(?<![A-Za-z0-9_\-])([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)\.([A-Za-z0-9_\-]+)(?![A-Za-z0-9_\-])"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var seen = Set<String>()
        var detections: [Detection] = []
        detections.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges == 4,
                  let tokenRange = Range(match.range(at: 0), in: text),
                  let headerRange = Range(match.range(at: 1), in: text),
                  let payloadRange = Range(match.range(at: 2), in: text)
            else {
                continue
            }

            let token = String(text[tokenRange])
            guard seen.insert(token).inserted else { continue }

            guard let headerData = decodeBase64URL(text[headerRange]),
                  let payloadData = decodeBase64URL(text[payloadRange]),
                  let headerObject = decodeJSONObject(from: headerData),
                  let payloadObject = decodeJSONObject(from: payloadData),
                  let headerJSON = normalizeJSON(headerObject),
                  let payloadJSON = normalizeJSON(payloadObject)
            else {
                continue
            }

            let claims = Claims(
                exp: decodeUnixDate(payloadObject["exp"]),
                iat: decodeUnixDate(payloadObject["iat"]),
                sub: payloadObject["sub"] as? String,
                iss: payloadObject["iss"] as? String
            )

            let isExpired: Bool?
            if let exp = claims.exp {
                isExpired = exp < now()
            } else {
                isExpired = nil
            }

            detections.append(
                Detection(
                    token: token,
                    confidence: 0.95,
                    headerJSON: headerJSON,
                    payloadJSON: payloadJSON,
                    claims: claims,
                    isExpired: isExpired
                )
            )
        }

        return detections
    }

    private func decodeBase64URL(_ segment: Substring) -> Data? {
        var s = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = (4 - (s.count % 4)) % 4
        if padding > 0 {
            s.append(String(repeating: "=", count: padding))
        }

        return Data(base64Encoded: s)
    }

    private func decodeJSONObject(from data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    private func normalizeJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeUnixDate(_ value: Any?) -> Date? {
        if let seconds = value as? TimeInterval {
            return Date(timeIntervalSince1970: seconds)
        }
        if let int = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(int))
        }
        if let str = value as? String, let seconds = TimeInterval(str) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
