import Foundation

public struct ColorDetector {
    public enum Format: String {
        case hex
        case rgb
        case rgba
        case hsl
        case hsla
        case named
    }

    public struct Detection: Equatable {
        public var raw: String
        public var format: Format
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
        public var alpha: Double
        public var confidence: Double

        public init(
            raw: String,
            format: Format,
            red: UInt8,
            green: UInt8,
            blue: UInt8,
            alpha: Double = 1.0,
            confidence: Double = 0.9
        ) {
            self.raw = raw
            self.format = format
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
            self.confidence = confidence
        }
    }

    /// Granularity used to interpret named colors. The detector itself accepts
    /// all named colors when explicitly asked; the strictness layer in
    /// `ContentTypeDetector` decides whether to accept them as a primary type.
    public enum NamedColorPolicy {
        /// Accept named colors only when the entire trimmed input is a single name.
        case wholeStringOnly
        /// Extract named colors anywhere in the text (used for Lax mode).
        case extract
        /// Don't recognize named colors at all.
        case disabled
    }

    public init() {}

    public func detect(in text: String, namedColorPolicy: NamedColorPolicy = .wholeStringOnly) -> [Detection] {
        var results: [Detection] = []
        var seen = Set<String>()

        // 1) Hex
        let hexPattern = #"(?<![0-9A-Za-z_])#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{3})(?![0-9A-Za-z_])"#
        for (raw, body) in matches(pattern: hexPattern, in: text, captureGroup: 1, fullGroup: 0) {
            if let det = makeHex(raw: raw, body: body), seen.insert(raw.lowercased()).inserted {
                results.append(det)
            }
        }

        // 2) rgb()/rgba()
        let rgbPattern = #"(?i)(?<![A-Za-z_])(rgba?)\s*\(\s*([^)]*)\)"#
        for (raw, _) in matches(pattern: rgbPattern, in: text, captureGroup: 0, fullGroup: 0) {
            if let det = parseFunctional(raw: raw), seen.insert(raw.lowercased()).inserted {
                results.append(det)
            }
        }

        // 3) hsl()/hsla()
        let hslPattern = #"(?i)(?<![A-Za-z_])(hsla?)\s*\(\s*([^)]*)\)"#
        for (raw, _) in matches(pattern: hslPattern, in: text, captureGroup: 0, fullGroup: 0) {
            if let det = parseFunctional(raw: raw), seen.insert(raw.lowercased()).inserted {
                results.append(det)
            }
        }

        // 4) Named colors
        switch namedColorPolicy {
        case .disabled:
            break
        case .wholeStringOnly:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rgb = Self.namedColors[trimmed.lowercased()] {
                let raw = trimmed
                if seen.insert(raw.lowercased()).inserted {
                    results.append(
                        Detection(raw: raw, format: .named, red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0, confidence: 0.85)
                    )
                }
            }
        case .extract:
            let pattern = #"(?i)\b([A-Za-z]{3,30})\b"#
            for (raw, _) in matches(pattern: pattern, in: text, captureGroup: 1, fullGroup: 0) {
                if let rgb = Self.namedColors[raw.lowercased()],
                   seen.insert(raw.lowercased()).inserted
                {
                    results.append(
                        Detection(raw: raw, format: .named, red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0, confidence: 0.7)
                    )
                }
            }
        }

        return results
    }

    // MARK: - Hex

    private func makeHex(raw: String, body: String) -> Detection? {
        let chars = Array(body)
        let r: UInt8
        let g: UInt8
        let b: UInt8
        var a: Double = 1.0
        switch chars.count {
        case 3:
            r = expand(chars[0])
            g = expand(chars[1])
            b = expand(chars[2])
        case 4:
            r = expand(chars[0])
            g = expand(chars[1])
            b = expand(chars[2])
            a = Double(expand(chars[3])) / 255.0
        case 6:
            guard let rr = byte(chars[0], chars[1]),
                  let gg = byte(chars[2], chars[3]),
                  let bb = byte(chars[4], chars[5]) else { return nil }
            r = rr; g = gg; b = bb
        case 8:
            guard let rr = byte(chars[0], chars[1]),
                  let gg = byte(chars[2], chars[3]),
                  let bb = byte(chars[4], chars[5]),
                  let aa = byte(chars[6], chars[7]) else { return nil }
            r = rr; g = gg; b = bb; a = Double(aa) / 255.0
        default:
            return nil
        }
        return Detection(raw: raw, format: .hex, red: r, green: g, blue: b, alpha: a, confidence: 0.95)
    }

    private func expand(_ c: Character) -> UInt8 {
        let v = UInt8(String(c), radix: 16) ?? 0
        return v * 16 + v
    }

    private func byte(_ a: Character, _ b: Character) -> UInt8? {
        guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
        return v
    }

    // MARK: - Functional rgb/rgba/hsl/hsla

    private func parseFunctional(raw: String) -> Detection? {
        guard let openParen = raw.firstIndex(of: "("),
              let closeParen = raw.lastIndex(of: ")") else { return nil }
        let funcName = raw[raw.startIndex..<openParen]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let inside = String(raw[raw.index(after: openParen)..<closeParen])

        let useCommas = inside.contains(",")
        let alphaSeparator: String? = inside.contains("/") ? "/" : nil

        var primary: [String]
        var alphaToken: String?

        if useCommas {
            primary = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if primary.count == 4 {
                alphaToken = primary.removeLast()
            }
        } else {
            var body = inside
            if let sep = alphaSeparator, let r = body.range(of: sep) {
                alphaToken = body[r.upperBound...].trimmingCharacters(in: .whitespaces)
                body = String(body[..<r.lowerBound])
            }
            primary = body
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0) }
        }

        guard primary.count == 3 else { return nil }

        let alpha: Double
        if let tok = alphaToken {
            guard let a = parseAlpha(tok) else { return nil }
            alpha = a
        } else {
            alpha = 1.0
        }

        let format: Format
        switch funcName {
        case "rgb":
            format = (alphaToken != nil) ? .rgba : .rgb
            guard let rgb = parseRGBComponents(primary) else { return nil }
            return Detection(raw: raw, format: format, red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha, confidence: 0.95)
        case "rgba":
            format = .rgba
            guard let rgb = parseRGBComponents(primary) else { return nil }
            return Detection(raw: raw, format: format, red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha, confidence: 0.95)
        case "hsl":
            format = (alphaToken != nil) ? .hsla : .hsl
            guard let hsl = parseHSLComponents(primary) else { return nil }
            let rgb = hslToRGB(h: hsl.0, s: hsl.1, l: hsl.2)
            return Detection(raw: raw, format: format, red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha, confidence: 0.95)
        case "hsla":
            format = .hsla
            guard let hsl = parseHSLComponents(primary) else { return nil }
            let rgb = hslToRGB(h: hsl.0, s: hsl.1, l: hsl.2)
            return Detection(raw: raw, format: format, red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha, confidence: 0.95)
        default:
            return nil
        }
    }

    private func parseRGBComponents(_ tokens: [String]) -> (UInt8, UInt8, UInt8)? {
        guard tokens.count == 3 else { return nil }
        var out: [UInt8] = []
        for t in tokens {
            if t.hasSuffix("%") {
                let body = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
                guard let v = Double(body), v >= 0, v <= 100 else { return nil }
                out.append(UInt8(round(v / 100.0 * 255.0)))
            } else {
                guard let v = Double(t) else { return nil }
                guard v >= 0, v <= 255 else { return nil }
                out.append(UInt8(round(v)))
            }
        }
        return (out[0], out[1], out[2])
    }

    private func parseHSLComponents(_ tokens: [String]) -> (Double, Double, Double)? {
        guard tokens.count == 3 else { return nil }
        var hueStr = tokens[0].lowercased()
        var hueScale = 1.0
        if hueStr.hasSuffix("deg") {
            hueStr = String(hueStr.dropLast(3))
        } else if hueStr.hasSuffix("rad") {
            hueStr = String(hueStr.dropLast(3))
            hueScale = 180.0 / .pi
        } else if hueStr.hasSuffix("turn") {
            hueStr = String(hueStr.dropLast(4))
            hueScale = 360.0
        } else if hueStr.hasSuffix("grad") {
            hueStr = String(hueStr.dropLast(4))
            hueScale = 360.0 / 400.0
        }
        guard let hRaw = Double(hueStr.trimmingCharacters(in: .whitespaces)) else { return nil }
        var h = hRaw * hueScale
        h = ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0)

        guard let s = parsePercent(tokens[1]) else { return nil }
        guard let l = parsePercent(tokens[2]) else { return nil }
        return (h, s, l)
    }

    private func parsePercent(_ token: String) -> Double? {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") {
            let body = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
            guard let v = Double(body), v >= 0, v <= 100 else { return nil }
            return v / 100.0
        }
        guard let v = Double(t), v >= 0, v <= 1 else { return nil }
        return v
    }

    private func parseAlpha(_ token: String) -> Double? {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") {
            let body = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
            guard let v = Double(body), v >= 0, v <= 100 else { return nil }
            return v / 100.0
        }
        guard let v = Double(t), v >= 0, v <= 1 else { return nil }
        return v
    }

    private func hslToRGB(h: Double, s: Double, l: Double) -> (UInt8, UInt8, UInt8) {
        if s == 0 {
            let v = UInt8(round(l * 255.0))
            return (v, v, v)
        }
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let hp = h / 60.0
        let x = c * (1.0 - abs(hp.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        case 5..<6: (r1, g1, b1) = (c, 0, x)
        default: (r1, g1, b1) = (0, 0, 0)
        }
        let m = l - c / 2.0
        let r = UInt8(min(255, max(0, round((r1 + m) * 255.0))))
        let g = UInt8(min(255, max(0, round((g1 + m) * 255.0))))
        let b = UInt8(min(255, max(0, round((b1 + m) * 255.0))))
        return (r, g, b)
    }

    // MARK: - Regex helper

    private func matches(
        pattern: String,
        in text: String,
        captureGroup: Int,
        fullGroup: Int
    ) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let results = regex.matches(in: text, options: [], range: range)
        var out: [(String, String)] = []
        out.reserveCapacity(results.count)
        for m in results {
            guard m.numberOfRanges > max(captureGroup, fullGroup) else { continue }
            guard let fullRange = Range(m.range(at: fullGroup), in: text) else { continue }
            let full = String(text[fullRange])
            let capture: String
            if captureGroup == 0 {
                capture = full
            } else if let r = Range(m.range(at: captureGroup), in: text) {
                capture = String(text[r])
            } else {
                continue
            }
            out.append((full, capture))
        }
        return out
    }

    // MARK: - Named CSS colors (CSS Color Module Level 4)

    static let namedColors: [String: (UInt8, UInt8, UInt8)] = [
        "aliceblue": (240, 248, 255), "antiquewhite": (250, 235, 215), "aqua": (0, 255, 255),
        "aquamarine": (127, 255, 212), "azure": (240, 255, 255), "beige": (245, 245, 220),
        "bisque": (255, 228, 196), "black": (0, 0, 0), "blanchedalmond": (255, 235, 205),
        "blue": (0, 0, 255), "blueviolet": (138, 43, 226), "brown": (165, 42, 42),
        "burlywood": (222, 184, 135), "cadetblue": (95, 158, 160), "chartreuse": (127, 255, 0),
        "chocolate": (210, 105, 30), "coral": (255, 127, 80), "cornflowerblue": (100, 149, 237),
        "cornsilk": (255, 248, 220), "crimson": (220, 20, 60), "cyan": (0, 255, 255),
        "darkblue": (0, 0, 139), "darkcyan": (0, 139, 139), "darkgoldenrod": (184, 134, 11),
        "darkgray": (169, 169, 169), "darkgrey": (169, 169, 169), "darkgreen": (0, 100, 0),
        "darkkhaki": (189, 183, 107), "darkmagenta": (139, 0, 139), "darkolivegreen": (85, 107, 47),
        "darkorange": (255, 140, 0), "darkorchid": (153, 50, 204), "darkred": (139, 0, 0),
        "darksalmon": (233, 150, 122), "darkseagreen": (143, 188, 143), "darkslateblue": (72, 61, 139),
        "darkslategray": (47, 79, 79), "darkslategrey": (47, 79, 79), "darkturquoise": (0, 206, 209),
        "darkviolet": (148, 0, 211), "deeppink": (255, 20, 147), "deepskyblue": (0, 191, 255),
        "dimgray": (105, 105, 105), "dimgrey": (105, 105, 105), "dodgerblue": (30, 144, 255),
        "firebrick": (178, 34, 34), "floralwhite": (255, 250, 240), "forestgreen": (34, 139, 34),
        "fuchsia": (255, 0, 255), "gainsboro": (220, 220, 220), "ghostwhite": (248, 248, 255),
        "gold": (255, 215, 0), "goldenrod": (218, 165, 32), "gray": (128, 128, 128),
        "grey": (128, 128, 128), "green": (0, 128, 0), "greenyellow": (173, 255, 47),
        "honeydew": (240, 255, 240), "hotpink": (255, 105, 180), "indianred": (205, 92, 92),
        "indigo": (75, 0, 130), "ivory": (255, 255, 240), "khaki": (240, 230, 140),
        "lavender": (230, 230, 250), "lavenderblush": (255, 240, 245), "lawngreen": (124, 252, 0),
        "lemonchiffon": (255, 250, 205), "lightblue": (173, 216, 230), "lightcoral": (240, 128, 128),
        "lightcyan": (224, 255, 255), "lightgoldenrodyellow": (250, 250, 210), "lightgray": (211, 211, 211),
        "lightgrey": (211, 211, 211), "lightgreen": (144, 238, 144), "lightpink": (255, 182, 193),
        "lightsalmon": (255, 160, 122), "lightseagreen": (32, 178, 170), "lightskyblue": (135, 206, 250),
        "lightslategray": (119, 136, 153), "lightslategrey": (119, 136, 153), "lightsteelblue": (176, 196, 222),
        "lightyellow": (255, 255, 224), "lime": (0, 255, 0), "limegreen": (50, 205, 50),
        "linen": (250, 240, 230), "magenta": (255, 0, 255), "maroon": (128, 0, 0),
        "mediumaquamarine": (102, 205, 170), "mediumblue": (0, 0, 205), "mediumorchid": (186, 85, 211),
        "mediumpurple": (147, 112, 219), "mediumseagreen": (60, 179, 113), "mediumslateblue": (123, 104, 238),
        "mediumspringgreen": (0, 250, 154), "mediumturquoise": (72, 209, 204), "mediumvioletred": (199, 21, 133),
        "midnightblue": (25, 25, 112), "mintcream": (245, 255, 250), "mistyrose": (255, 228, 225),
        "moccasin": (255, 228, 181), "navajowhite": (255, 222, 173), "navy": (0, 0, 128),
        "oldlace": (253, 245, 230), "olive": (128, 128, 0), "olivedrab": (107, 142, 35),
        "orange": (255, 165, 0), "orangered": (255, 69, 0), "orchid": (218, 112, 214),
        "palegoldenrod": (238, 232, 170), "palegreen": (152, 251, 152), "paleturquoise": (175, 238, 238),
        "palevioletred": (219, 112, 147), "papayawhip": (255, 239, 213), "peachpuff": (255, 218, 185),
        "peru": (205, 133, 63), "pink": (255, 192, 203), "plum": (221, 160, 221),
        "powderblue": (176, 224, 230), "purple": (128, 0, 128), "rebeccapurple": (102, 51, 153),
        "red": (255, 0, 0), "rosybrown": (188, 143, 143), "royalblue": (65, 105, 225),
        "saddlebrown": (139, 69, 19), "salmon": (250, 128, 114), "sandybrown": (244, 164, 96),
        "seagreen": (46, 139, 87), "seashell": (255, 245, 238), "sienna": (160, 82, 45),
        "silver": (192, 192, 192), "skyblue": (135, 206, 235), "slateblue": (106, 90, 205),
        "slategray": (112, 128, 144), "slategrey": (112, 128, 144), "snow": (255, 250, 250),
        "springgreen": (0, 255, 127), "steelblue": (70, 130, 180), "tan": (210, 180, 140),
        "teal": (0, 128, 128), "thistle": (216, 191, 216), "tomato": (255, 99, 71),
        "transparent": (0, 0, 0), "turquoise": (64, 224, 208), "violet": (238, 130, 238),
        "wheat": (245, 222, 179), "white": (255, 255, 255), "whitesmoke": (245, 245, 245),
        "yellow": (255, 255, 0), "yellowgreen": (154, 205, 50)
    ]
}
