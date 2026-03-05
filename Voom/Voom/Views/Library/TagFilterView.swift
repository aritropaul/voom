import SwiftUI
import VoomCore

struct TagFilterView: View {
    let availableTags: [RecordingTag]
    @Binding var selectedTagIDs: Set<UUID>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableTags) { tag in
                    let isSelected = selectedTagIDs.contains(tag.id)
                    Button {
                        if isSelected {
                            selectedTagIDs.remove(tag.id)
                        } else {
                            selectedTagIDs.insert(tag.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .blue)
                                .frame(width: 6, height: 6)
                            Text(tag.name)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(isSelected ? .white : VoomTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(isSelected
                                    ? (Color(hex: tag.colorHex) ?? .blue).opacity(0.3)
                                    : VoomTheme.backgroundTertiary
                                )
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected
                                    ? (Color(hex: tag.colorHex) ?? .blue)
                                    : VoomTheme.borderSubtle,
                                    lineWidth: 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !selectedTagIDs.isEmpty {
                    Button {
                        selectedTagIDs.removeAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(VoomTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
