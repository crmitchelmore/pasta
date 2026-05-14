import SwiftUI

struct ColorSwatchPreview: View {
    struct Swatch {
        let raw: String
        let format: String
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: Double
    }

    let swatch: Swatch

    private var color: Color {
        Color(.sRGB,
              red: Double(swatch.red) / 255.0,
              green: Double(swatch.green) / 255.0,
              blue: Double(swatch.blue) / 255.0,
              opacity: swatch.alpha)
    }

    private var hexString: String {
        if swatch.alpha < 1.0 {
            return String(format: "#%02X%02X%02X%02X",
                          swatch.red, swatch.green, swatch.blue,
                          UInt8(round(swatch.alpha * 255)))
        }
        return String(format: "#%02X%02X%02X", swatch.red, swatch.green, swatch.blue)
    }

    private var rgbString: String {
        if swatch.alpha < 1.0 {
            return String(format: "rgba(%d, %d, %d, %.2f)",
                          swatch.red, swatch.green, swatch.blue, swatch.alpha)
        }
        return "rgb(\(swatch.red), \(swatch.green), \(swatch.blue))"
    }

    private var hslString: String {
        let (h, s, l) = rgbToHSL(r: swatch.red, g: swatch.green, b: swatch.blue)
        let hi = Int(round(h))
        let si = Int(round(s * 100))
        let li = Int(round(l * 100))
        if swatch.alpha < 1.0 {
            return String(format: "hsla(%d, %d%%, %d%%, %.2f)", hi, si, li, swatch.alpha)
        }
        return "hsl(\(hi), \(si)%, \(li)%)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color)
                .frame(width: 80, height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(swatch.raw)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if !swatch.format.isEmpty {
                    Text(swatch.format.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(hexString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(rgbString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(hslString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rgbToHSL(r: UInt8, g: UInt8, b: UInt8) -> (Double, Double, Double) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxV = max(rf, gf, bf)
        let minV = min(rf, gf, bf)
        let l = (maxV + minV) / 2.0
        let delta = maxV - minV
        if delta == 0 { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2.0 - maxV - minV) : delta / (maxV + minV)
        var h: Double = 0
        if maxV == rf {
            h = (gf - bf) / delta + (gf < bf ? 6 : 0)
        } else if maxV == gf {
            h = (bf - rf) / delta + 2
        } else {
            h = (rf - gf) / delta + 4
        }
        h *= 60
        return (h, s, l)
    }
}
