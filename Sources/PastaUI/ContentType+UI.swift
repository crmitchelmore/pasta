import PastaCore
import SwiftUI

extension ContentType {
    var systemImageName: String {
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

    var tint: Color {
        PastaTheme.tint(for: self)
    }

    var displayTitle: String {
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
        case .shellCommand: return "Shell Command"
        case .screenshot: return "Screenshot"
        case .url: return "URL"
        default:
            return rawValue.capitalized
        }
    }

    var pickerTitle: String {
        displayTitle
    }

    var badgeTitle: String {
        switch self {
        case .envVar: return "ENV"
        case .envVarBlock: return "ENV BLOCK"
        case .screenshot: return "SS"
        case .shellCommand: return "SHELL"
        case .phoneNumber: return "PHONE"
        case .ipAddress: return "IP"
        case .uuid: return "UUID"
        case .hash: return "HASH"
        case .apiKey: return "API KEY"
        default:
            return displayTitle.uppercased()
        }
    }
}
