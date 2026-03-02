import SwiftUI

// MARK: - Design Tokens

enum VoomTheme {
    // MARK: Colors

    static let backgroundPrimary   = Color(nsColor: NSColor(white: 0.07, alpha: 1))
    static let backgroundSecondary = Color(nsColor: NSColor(white: 0.10, alpha: 1))
    static let backgroundTertiary  = Color(nsColor: NSColor(white: 0.13, alpha: 1))
    static let backgroundHover     = Color.white.opacity(0.04)
    static let backgroundSelected  = Color.white.opacity(0.08)

    static let borderSubtle  = Color.white.opacity(0.08)
    static let borderMedium  = Color.white.opacity(0.12)
    static let borderStrong  = Color.white.opacity(0.18)

    static let textPrimary    = Color.white.opacity(0.92)
    static let textSecondary  = Color.white.opacity(0.60)
    static let textTertiary   = Color.white.opacity(0.40)
    static let textQuaternary = Color.white.opacity(0.25)

    static let accentRed    = Color(nsColor: NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1))
    static let accentGreen  = Color(nsColor: NSColor(red: 0.25, green: 0.78, blue: 0.45, alpha: 1))
    static let accentOrange = Color(nsColor: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1))

    // Tag colors
    static let tagBlue   = Color(nsColor: NSColor(red: 0.37, green: 0.36, blue: 0.90, alpha: 1))
    static let tagPurple = Color(nsColor: NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1))
    static let tagPink   = Color(nsColor: NSColor(red: 1.0, green: 0.22, blue: 0.37, alpha: 1))
    static let tagTeal   = Color(nsColor: NSColor(red: 0.39, green: 0.82, blue: 1.0, alpha: 1))

    // MARK: Typography

    static func fontTitle() -> Font { .system(size: 18, weight: .semibold) }
    static func fontHeadline() -> Font { .system(size: 14, weight: .semibold) }
    static func fontBody() -> Font { .system(size: 13) }
    static func fontCaption() -> Font { .system(size: 11) }
    static func fontMono() -> Font { .system(size: 10, design: .monospaced) }
    static func fontBadge() -> Font { .system(size: 10, weight: .medium) }

    // MARK: Spacing

    static let spacingXS:  CGFloat = 4
    static let spacingSM:  CGFloat = 8
    static let spacingMD:  CGFloat = 12
    static let spacingLG:  CGFloat = 16
    static let spacingXL:  CGFloat = 24
    static let spacingXXL: CGFloat = 32

    // MARK: Radii

    static let radiusSmall:  CGFloat = 4
    static let radiusMedium: CGFloat = 8
    static let radiusLarge:  CGFloat = 12
}

// MARK: - VoomBadge

struct VoomBadge: View {
    let text: String
    let color: Color
    let icon: String?

    init(_ text: String, color: Color, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .font(VoomTheme.fontBadge())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }
}

// MARK: - VoomSectionHeader

struct VoomSectionHeader: View {
    let icon: String
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VoomTheme.textTertiary)
            Text(title)
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoomTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(VoomTheme.backgroundTertiary)
                    )
            }
        }
    }
}

// MARK: - Card Modifier

struct VoomCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .fill(VoomTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

extension View {
    func voomCard() -> some View {
        modifier(VoomCardModifier())
    }
}

// MARK: - Empty State Component

struct VoomEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var iconSize: CGFloat = 72
    var symbolSize: CGFloat = 28

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            ZStack {
                Circle()
                    .fill(VoomTheme.backgroundTertiary)
                    .frame(width: iconSize, height: iconSize)
                Image(systemName: icon)
                    .font(.system(size: symbolSize, weight: .light))
                    .foregroundStyle(VoomTheme.textTertiary)
            }
            VStack(spacing: VoomTheme.spacingSM) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VoomTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(VoomTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
