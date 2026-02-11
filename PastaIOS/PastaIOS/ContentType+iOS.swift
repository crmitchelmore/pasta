import PastaCore
import SwiftUI

/// iOS-specific UI extensions for ContentType.
extension ContentType {
    var displayName: String {
        switch self {
        case .envVar: return "Env"
        case .envVarBlock: return "Env Block"
        case .phoneNumber: return "Phone"
        case .ipAddress: return "IP Address"
        case .uuid: return "UUID"
        case .hash: return "Hash"
        case .jwt: return "JWT"
        case .apiKey: return "API Key"
        case .filePath: return "File Path"
        case .shellCommand: return "Shell"
        case .screenshot: return "Screenshot"
        case .url: return "URL"
        default: return rawValue.capitalized
        }
    }

    var iconName: String {
        switch self {
        case .text: return "text.alignleft"
        case .email: return "envelope"
        case .phoneNumber: return "phone"
        case .ipAddress: return "network"
        case .uuid: return "number"
        case .hash: return "number"
        case .jwt: return "key"
        case .apiKey: return "key.fill"
        case .envVar, .envVarBlock: return "terminal"
        case .prose: return "text.book.closed"
        case .image: return "photo"
        case .screenshot: return "camera.viewfinder"
        case .filePath: return "doc"
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .shellCommand: return "apple.terminal"
        case .unknown: return "questionmark"
        }
    }

    var tintColor: Color {
        switch self {
        case .text, .prose: return .primary
        case .email: return .blue
        case .phoneNumber: return .green
        case .ipAddress: return .orange
        case .uuid: return .purple
        case .hash: return .indigo
        case .jwt: return .red
        case .apiKey: return .red
        case .envVar, .envVarBlock: return .teal
        case .image, .screenshot: return .pink
        case .filePath: return .brown
        case .url: return .blue
        case .code: return .mint
        case .shellCommand: return .cyan
        case .unknown: return .gray
        }
    }
}
