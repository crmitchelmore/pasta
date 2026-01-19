import PastaCore
import SwiftUI

extension ContentType {
    var systemImageName: String {
        switch self {
        case .text: return "text.alignleft"
        case .email: return "envelope"
        case .jwt: return "key"
        case .envVar, .envVarBlock: return "terminal"
        case .prose: return "text.book.closed"
        case .image: return "photo"
        case .filePath: return "doc"
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .unknown: return "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .text: return .secondary
        case .email: return .blue
        case .jwt: return .purple
        case .envVar, .envVarBlock: return .green
        case .prose: return .teal
        case .image: return .pink
        case .filePath: return .brown
        case .url: return .indigo
        case .code: return .orange
        case .unknown: return .gray
        }
    }
}
