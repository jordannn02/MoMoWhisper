import SwiftUI

enum AppTheme {
    static let background = Color(hex: 0xE8EFEC)
    static let surface = Color(hex: 0xFAFBF8)
    static let surfaceAlt = Color(hex: 0xDDEAE5)
    static let chrome = Color(hex: 0xD1E2DC)
    static let controlSurface = Color(hex: 0xF4F7F3)
    static let controlSurfaceActive = Color(hex: 0xE2F3EE)
    static let primaryInk = Color(hex: 0x17324D)
    static let actionTeal = Color(hex: 0x0D9488)
    static let codexBlue = Color(hex: 0x2563EB)
    static let recordingRed = Color(hex: 0xDC2626)
    static let coverageAmber = Color(hex: 0xD97706)
    static let textPrimary = Color(hex: 0x111827)
    static let textSecondary = Color(hex: 0x5B6472)
    static let border = Color(hex: 0xDDE3E1)

    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 8
    static let spacing: CGFloat = 8
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, opacity: opacity)
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case live
    case commandCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live:
            return "現場"
        case .commandCenter:
            return "交付"
        }
    }

    var systemImage: String {
        switch self {
        case .live:
            return "waveform"
        case .commandCenter:
            return "paperplane"
        }
    }
}

enum TrustSignalTone {
    case ready
    case warning
    case danger
    case neutral

    var color: Color {
        switch self {
        case .ready:
            return AppTheme.actionTeal
        case .warning:
            return AppTheme.coverageAmber
        case .danger:
            return AppTheme.recordingRed
        case .neutral:
            return AppTheme.textSecondary
        }
    }
}

extension MeetingSessionMetadata {
    var isMeaningfulForHandoff: Bool {
        transcriptCharacterCount >= 300 || highlightCharacterCount >= 80
    }

    var validityLabel: String {
        isMeaningfulForHandoff ? "有效" : "空/測試"
    }

    var validityTone: TrustSignalTone {
        isMeaningfulForHandoff ? .ready : .warning
    }
}
