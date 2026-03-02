import SwiftUI

struct FolderRow: View {
    let folder: Folder
    let recordingCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(folderColor)
            Text(folder.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? VoomTheme.textPrimary : VoomTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text("\(recordingCount)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(VoomTheme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(VoomTheme.backgroundTertiary)
                )
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .fill(isSelected ? VoomTheme.backgroundSelected : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var folderColor: Color {
        if let hex = folder.colorHex {
            return Color(hex: hex) ?? VoomTheme.accentOrange
        }
        return VoomTheme.accentOrange
    }
}

// MARK: - Color hex extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
