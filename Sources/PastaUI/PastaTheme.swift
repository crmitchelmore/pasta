import AppKit
import PastaCore
import SwiftUI

public enum PastaTheme {
    // Fresh coral-orange tint - vibrant and modern
    public static let accent = Color(red: 1.0, green: 0.45, blue: 0.35) // coral
    
    // Warm pasta palette
    static let golden = Color(red: 0.94, green: 0.74, blue: 0.18)
    static let tomato = Color(red: 0.84, green: 0.22, blue: 0.18)
    static let basil = Color(red: 0.18, green: 0.55, blue: 0.30)
    static let olive = Color(red: 0.35, green: 0.45, blue: 0.22)
    static let ink = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let cream = Color(red: 0.98, green: 0.96, blue: 0.90)

    // MARK: Semantic colors
    //
    // Use these instead of ad-hoc `.orange` / `.green` / `.red` so that the
    // same meaning always maps to the same hue across surfaces.

    /// Pinned entries (row glyph, sidebar filter, section header).
    public static let pin = Color.orange
    /// Positive confirmation (copy toast, "granted" states).
    public static let success = Color.green
    /// Irreversible actions (delete, clear, reset).
    public static let destructive = Color.red
    /// Quick Search command mode (`!` prefix) chrome.
    public static let command = Color.orange

    // MARK: Layout tokens

    public enum Radius {
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 12
        public static let xl: CGFloat = 16
    }

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
    }

    public static func tint(for type: ContentType) -> Color {
        switch type {
        case .text: return .secondary
        case .email: return tomato
        case .phoneNumber: return .teal
        case .ipAddress: return .mint
        case .uuid: return .gray
        case .hash: return .gray
        case .jwt: return ink
        case .apiKey: return .orange
        case .envVar, .envVarBlock: return basil
        case .prose: return olive
        case .image: return .pink
        case .screenshot: return .cyan
        case .filePath: return .brown
        case .url: return .indigo
        case .code: return golden
        case .shellCommand: return .green
        case .color: return .pink
        case .macAddress: return .mint
        case .creditCard: return tomato
        case .iban: return .indigo
        case .unknown: return .gray
        }
    }
}

// MARK: - Appearance Mode

public enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark
    
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Appearance View Modifier

public struct AppearanceModifier: ViewModifier {
    @AppStorage("pasta.appearance") private var appearance: String = "system"
    
    private var mode: AppearanceMode {
        AppearanceMode(rawValue: appearance) ?? .system
    }
    
    public init() {}
    
    public func body(content: Content) -> some View {
        content
            .preferredColorScheme(mode.colorScheme)
    }
}

public extension View {
    func withAppearance() -> some View {
        modifier(AppearanceModifier())
    }
}
