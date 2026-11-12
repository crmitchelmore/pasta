import Foundation

enum DetectorTestSupport {
    /// Builds JWT-shaped strings at runtime so no literal token trips secret scanning.
    static func makeJWT(header: String, payload: String, signature: String) -> String {
        [header, payload, signature].map(base64URL).joined(separator: ".")
    }

    static func base64URL(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func parseJSON(_ json: String?) -> [String: Any]? {
        guard let json else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    static func composition(_ json: String?) -> [String: Any]? {
        parseJSON(json)?["composition"] as? [String: Any]
    }
}
