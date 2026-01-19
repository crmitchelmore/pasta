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
        PastaTheme.tint(for: self)
    }
}
