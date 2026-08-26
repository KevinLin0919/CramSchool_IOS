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

    // One place to map a verdict to how it looks, so a new state cannot be
    // handled in four views and forgotten in a fifth.
    static func color(for verdict: GradingVerdict) -> Color {
        switch verdict {
        case .correct: return ok
        case .wrong: return bad
        case .unsure: return warn
        }
    }

    static func background(for verdict: GradingVerdict) -> Color {
        switch verdict {
        case .correct: return okBg
        case .wrong: return badBg
        case .unsure: return warnBg
        }
    }

    static func glyph(for verdict: GradingVerdict) -> String {
        switch verdict {
        case .correct: return "checkmark"
        case .wrong: return "xmark"
        case .unsure: return "questionmark"
        }
    }

    // Readable content widths for the universal (iPhone + iPad) layout.
    // On iPhone the screen is narrower than these caps, so the modifier
    // below is a no-op; on iPad it constrains content and centers it
    // instead of letting everything stretch edge to edge.
    enum Width {
        static let content: CGFloat = 640   // lists, forms, headers, cards
        static let contentRegular: CGFloat = 860  // the same, given a tablet's width
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

// Whether the current window is wide enough to lay out as a tablet rather
// than a scaled-up phone. Read from the size class, not the idiom, so an
// iPad in a narrow Split View column correctly falls back to the phone
// layout instead of trying to fit two columns into 320pt.
struct RegularWidth<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(sizeClass == .regular)
    }
}

// MARK: - Bottom chrome geometry

extension AG {
    /// The window's bottom safe-area inset, read from UIKit.
    ///
    /// SwiftUI's `.ignoresSafeArea` is the obvious way to place something past
    /// this line and it does nothing inside an overlay on a view that already
    /// respects the safe area — there is no inset left there to reclaim. Every
    /// bottom-anchored control here therefore measures the inset and moves by
    /// the difference, which does not depend on that behaviour at all.
    static var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    /// Clearance from the bottom of the screen to the bottom of the tab bar.
    /// The home indicator sits roughly 8–13pt up, so this leaves it visible
    /// with a few points to spare.
    static let tabBarBottomGap: CGFloat = 18

    // The bar's height, from its parts rather than as a number to keep in
    // step by hand. Guessing it at 56 when it is really 70 is what put the
    // action button flat against it: the missing 14pt was the entire gap.

    /// The scan button's circle, and the height the row is measured from.
    static let tabBarIconSlot: CGFloat = 44
    static let tabBarItemSpacing: CGFloat = 2
    static let tabBarLabelHeight: CGFloat = 12
    static let tabBarPadding: CGFloat = 6

    /// The glyph on the side tabs, and its distance from the label.
    ///
    /// These are not the scan button's numbers and cannot be. Its circle is a
    /// filled 44pt shape, so its ink reaches to within 2pt of the label; a
    /// 21pt glyph centred in a 44pt box leaves 11pt of air under it and reads
    /// as a caption that drifted away from its icon. Drawing the glyph larger
    /// and sitting it closer closes most of that gap.
    ///
    /// Most, not all. A circle 44pt tall beside a glyph 26pt tall cannot have
    /// both its labels aligned with the others AND every group centred in the
    /// bar — the arithmetic does not allow it. Centred wins, and the labels
    /// land within about 5pt of each other, which nobody reads as an error.
    static let tabBarIconSize: CGFloat = 26
    static let tabBarLabelGap: CGFloat = 7

    /// What every button in the row is laid out inside, so the glyph group can
    /// be centred without the row's height following it.
    static var tabBarContentHeight: CGFloat {
        tabBarIconSlot + tabBarItemSpacing + tabBarLabelHeight
    }

    static var tabBarHeight: CGFloat {
        tabBarPadding * 2 + tabBarContentHeight
    }

    /// Where a screen's own bottom-anchored content has to stop, measured from
    /// the physical bottom edge. Anything positioned against the safe area
    /// instead lands in a different place on every device — and on one with no
    /// bottom inset, underneath the bar.
    ///
    /// The gap above the bar matches the gap below it, so the bar reads as
    /// floating in a space rather than pinned to one edge of it.
    static var bottomChromeClearance: CGFloat {
        tabBarBottomGap + tabBarHeight + tabBarBottomGap
    }

    /// Bottom padding that puts a control's edge `distance` above the physical
    /// bottom, whatever the device's inset happens to be.
    static func padding(above distance: CGFloat) -> CGFloat {
        max(0, distance - bottomSafeInset)
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass where the OS has it, the material it replaced where it
    /// does not.
    ///
    /// The app deploys to iOS 17 and builds against the iOS 26 SDK, so system
    /// surfaces — every Form, sheet, alert and navigation bar — already render
    /// as glass on a current device while anything hand-rolled here does not.
    /// This is what closes that gap for the hand-rolled chrome, in one place,
    /// so call sites do not each carry their own availability fork.
    ///
    /// Only for surfaces that FLOAT over content. Glass earns its cost by
    /// sampling what passes beneath it; over a flat background it is an
    /// expensive way to draw a slightly tinted rectangle.
    @ViewBuilder
    func floatingGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(AG.border1, lineWidth: 0.5))
        }
    }
}
