import SwiftUI

// Design tokens ported from the Claude Design project (tokens.js).
// Primary brand color: #2d5a3d.

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

enum AG {
    // brand
    static let brand = Color(hex: 0x2D5A3D)
    static let brandDeep = Color(hex: 0x1B3D28)
    static let brandSoft = Color(hex: 0xE6F0EA)
    static let brand50 = Color(hex: 0xEEF6F1)
    static let brand100 = Color(hex: 0xD6EADE)
    static let brand500 = Color(hex: 0x52B788)

    // neutrals
    static let fg1 = Color(hex: 0x1F2D3D)
    static let fg2 = Color(hex: 0x5F6B7A)
    static let fg3 = Color(hex: 0x8A93A0)
    static let fg4 = Color(hex: 0xC5CCD4)
    static let bg1 = Color.white
    static let bg2 = Color(hex: 0xF5F5F5)
    static let bg3 = Color(hex: 0xEEF4F8)
    static let border1 = Color(hex: 0x3C3C43, alpha: 0.18)
    static let border2 = Color(hex: 0xE4E9ED)
    static let borderStrong = Color(hex: 0xD7DEE5)

    // semantic
    static let ok = Color(hex: 0x2D8A5F)
    static let okBg = Color(hex: 0xE8F5EC)
    static let bad = Color(hex: 0xD93025)
    static let badBg = Color(hex: 0xFDECEA)
    static let warn = Color(hex: 0xFF9500)
    static let warnBg = Color(hex: 0xFFF4D6)

    // Readable content widths for the universal (iPhone + iPad) layout.
    // On iPhone the screen is narrower than these caps, so the modifier
    // below is a no-op; on iPad it constrains content and centers it
    // instead of letting everything stretch edge to edge.
    enum Width {
        static let content: CGFloat = 640   // lists, forms, headers, cards
        static let wide: CGFloat = 720      // results image column
        static let action: CGFloat = 440    // primary action buttons
        static let card: CGFloat = 520      // floating scanner cards
        static let tabBar: CGFloat = 480    // custom tab bar cluster
    }

    // subject accent colors (SUBJECT_TINT in templates.jsx)
    static func subjectTint(_ subject: String) -> Color {
        switch subject {
        case "數學": return Color(hex: 0x2563EB)
        case "英文", "英語": return Color(hex: 0x7C3AED)
        case "理化", "物理", "化學": return Color(hex: 0x0891B2)
        case "國文": return Color(hex: 0xDC2626)
        case "歷史": return Color(hex: 0xB45309)
        case "地理": return Color(hex: 0x059669)
        case "生物", "自然": return Color(hex: 0x16A34A)
        case "社會", "公民": return Color(hex: 0x9333EA)
        default: return fg2
        }
    }
}

extension View {
    // Cap content to a readable width and center it. No-op on iPhone
    // (content is already narrower than the cap); on iPad it keeps the
    // content in a centered column instead of stretching full width.
    func centeredContent(_ maxWidth: CGFloat = AG.Width.content) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
