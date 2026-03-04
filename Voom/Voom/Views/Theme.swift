import SwiftUI

// MARK: - Design Tokens

enum VoomTheme {
    // MARK: Colors

    static let backgroundPrimary   = Color(nsColor: NSColor(white: 0.10, alpha: 1))
    static let backgroundSecondary = Color(nsColor: NSColor(white: 0.08, alpha: 1))
    static let backgroundTertiary  = Color(nsColor: NSColor(white: 0.17, alpha: 1))
    static let backgroundCard      = Color(nsColor: NSColor(white: 0.14, alpha: 1))
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

    static func fontTitle() -> Font { .system(size: 15, weight: .semibold) }
    static func fontHeadline() -> Font { .system(size: 12, weight: .semibold) }
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(VoomTheme.textTertiary)
            Text(title)
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VoomTheme.textTertiary)
            }
            Spacer()
        }
    }
}

// MARK: - Action Bar Button

struct ActionBarButton: View {
    let icon: String
    var label: String? = nil
    var tint: Color? = nil
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private var foregroundColor: Color {
        if isActive { return Color.white }
        if let tint { return tint }
        return isHovered ? VoomTheme.textPrimary : VoomTheme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, label != nil ? 10 : 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? VoomTheme.backgroundTertiary : VoomTheme.backgroundCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Tool Pill Button

struct ToolPillButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isActive ? Color.white : (isHovered ? VoomTheme.textPrimary : VoomTheme.textSecondary))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.12) : (isHovered ? VoomTheme.backgroundTertiary : VoomTheme.backgroundCard))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? Color.white.opacity(0.3) : VoomTheme.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Card Modifier

struct VoomCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                        .fill(VoomTheme.backgroundCard.opacity(0.4))
                    RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                        .fill(.thinMaterial)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                    .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
    }
}

extension View {
    func voomCard() -> some View {
        modifier(VoomCardModifier())
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = CGPoint(
                x: bounds.minX + result.positions[index].x,
                y: bounds.minY + result.positions[index].y
            )
            subview.place(at: point, anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
            totalHeight = y + rowHeight
        }
        return (positions, CGSize(width: totalWidth, height: totalHeight))
    }
}

// MARK: - Staggered Appear Modifier

struct StaggeredAppear: ViewModifier {
    let index: Int
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .animation(
                .spring(response: 0.45, dampingFraction: 0.85).delay(Double(index) * 0.06),
                value: visible
            )
            .onAppear {
                Task { @MainActor in
                    visible = true
                }
            }
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
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
