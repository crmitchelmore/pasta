import PastaCore
import SwiftUI

public enum PastaTheme {
    // Warm pasta palette
    public static let accent = Color(red: 0.94, green: 0.74, blue: 0.18) // golden

    static let tomato = Color(red: 0.84, green: 0.22, blue: 0.18)
    static let basil = Color(red: 0.18, green: 0.55, blue: 0.30)
    static let olive = Color(red: 0.35, green: 0.45, blue: 0.22)
    static let ink = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let cream = Color(red: 0.98, green: 0.96, blue: 0.90)

    public static func tint(for type: ContentType) -> Color {
        switch type {
        case .text: return .secondary
        case .email: return tomato
        case .phoneNumber: return .teal
        case .ipAddress: return .mint
        case .uuid: return .gray
        case .hash: return .gray
        case .jwt: return ink
        case .envVar, .envVarBlock: return basil
        case .prose: return olive
        case .image: return .pink
        case .screenshot: return .cyan
        case .filePath: return .brown
        case .url: return .indigo
        case .code: return accent
        case .shellCommand: return .green
        case .unknown: return .gray
        }
    }
}
