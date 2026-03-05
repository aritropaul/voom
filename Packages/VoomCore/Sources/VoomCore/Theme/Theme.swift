import SwiftUI

// MARK: - Design Tokens

public enum VoomTheme {
    // MARK: Colors

    public static let backgroundPrimary   = Color(nsColor: NSColor(white: 0.10, alpha: 1))
    public static let backgroundSecondary = Color(nsColor: NSColor(white: 0.08, alpha: 1))
    public static let backgroundTertiary  = Color(nsColor: NSColor(white: 0.17, alpha: 1))
    public static let backgroundCard      = Color(nsColor: NSColor(white: 0.14, alpha: 1))
    public static let backgroundHover     = Color.white.opacity(0.04)
    public static let backgroundSelected  = Color.white.opacity(0.08)

    public static let borderSubtle  = Color.white.opacity(0.08)
    public static let borderMedium  = Color.white.opacity(0.12)
    public static let borderStrong  = Color.white.opacity(0.18)

    public static let textPrimary    = Color.white.opacity(0.92)
    public static let textSecondary  = Color.white.opacity(0.60)
    public static let textTertiary   = Color.white.opacity(0.40)
    public static let textQuaternary = Color.white.opacity(0.25)

    public static let accentRed    = Color(nsColor: NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1))
    public static let accentGreen  = Color(nsColor: NSColor(red: 0.25, green: 0.78, blue: 0.45, alpha: 1))
    public static let accentOrange = Color(nsColor: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1))

    // Tag colors
    public static let tagBlue   = Color(nsColor: NSColor(red: 0.37, green: 0.36, blue: 0.90, alpha: 1))
    public static let tagPurple = Color(nsColor: NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1))
    public static let tagPink   = Color(nsColor: NSColor(red: 1.0, green: 0.22, blue: 0.37, alpha: 1))
    public static let tagTeal   = Color(nsColor: NSColor(red: 0.39, green: 0.82, blue: 1.0, alpha: 1))

    // MARK: Typography

    public static func fontTitle() -> Font { .system(size: 15, weight: .semibold) }
    public static func fontHeadline() -> Font { .system(size: 12, weight: .semibold) }
    public static func fontBody() -> Font { .system(size: 13) }
    public static func fontCaption() -> Font { .system(size: 11) }
    public static func fontMono() -> Font { .system(size: 10, design: .monospaced) }
    public static func fontBadge() -> Font { .system(size: 10, weight: .medium) }

    // MARK: Spacing

    public static let spacingXS:  CGFloat = 4
    public static let spacingSM:  CGFloat = 8
    public static let spacingMD:  CGFloat = 12
    public static let spacingLG:  CGFloat = 16
    public static let spacingXL:  CGFloat = 24
    public static let spacingXXL: CGFloat = 32

    // MARK: Radii

    public static let radiusSmall:  CGFloat = 4
    public static let radiusMedium: CGFloat = 8
    public static let radiusLarge:  CGFloat = 12
}

// MARK: - VoomBadge

public struct VoomBadge: View {
    public let text: String
    public let color: Color
    public let icon: String?

    public init(_ text: String, color: Color, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    public var body: some View {
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

public struct VoomSectionHeader: View {
    public let icon: String
    public let title: String
    public var count: Int? = nil

    public init(icon: String, title: String, count: Int? = nil) {
        self.icon = icon
        self.title = title
        self.count = count
    }

    public var body: some View {
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

public struct ActionBarButton: View {
    public let icon: String
    public var label: String? = nil
    public var tint: Color? = nil
    public var isActive: Bool = false
    public let action: () -> Void

    @State private var isHovered = false

    public init(icon: String, label: String? = nil, tint: Color? = nil, isActive: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.tint = tint
        self.isActive = isActive
        self.action = action
    }

    private var foregroundColor: Color {
        if isActive { return Color.white }
        if let tint { return tint }
        return isHovered ? VoomTheme.textPrimary : VoomTheme.textSecondary
    }

    public var body: some View {
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

public struct ToolPillButton: View {
    public let icon: String
    public let label: String
    public var isActive: Bool = false
    public let action: () -> Void

    @State private var isHovered = false

    public init(icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
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

public struct VoomCardModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                    RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                        .fill(.thickMaterial)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                    .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
    }
}

public extension View {
    func voomCard() -> some View {
        modifier(VoomCardModifier())
    }
}

// MARK: - Flow Layout

public struct FlowLayout: Layout {
    public var spacing: CGFloat = 8

    public init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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

public struct StaggeredAppear: ViewModifier {
    public let index: Int
    @State private var visible = false

    public init(index: Int) {
        self.index = index
    }

    public func body(content: Content) -> some View {
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

public extension View {
    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

// MARK: - Empty State Component

public struct VoomEmptyState: View {
    public let icon: String
    public let title: String
    public let subtitle: String
    public var iconSize: CGFloat = 72
    public var symbolSize: CGFloat = 28

    public init(icon: String, title: String, subtitle: String, iconSize: CGFloat = 72, symbolSize: CGFloat = 28) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.iconSize = iconSize
        self.symbolSize = symbolSize
    }

    public var body: some View {
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
