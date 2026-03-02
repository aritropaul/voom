import SwiftUI

struct TagManager: View {
    @Environment(RecordingStore.self) private var store
    @Binding var isPresented: Bool

    @State private var newTagName = ""
    @State private var selectedColor = "5E5CE6"

    static let colorPresets = [
        ("5E5CE6", "Indigo"),
        ("BF5AF2", "Purple"),
        ("FF375F", "Pink"),
        ("64D2FF", "Teal"),
        ("30D158", "Green"),
        ("FF9F0A", "Orange"),
        ("FFD60A", "Yellow"),
        ("AC8E68", "Brown"),
    ]

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            Text("Manage Tags")
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)

            // Existing tags
            if !store.availableTags.isEmpty {
                VStack(spacing: 4) {
                    ForEach(store.availableTags) { tag in
                        HStack {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .blue)
                                .frame(width: 10, height: 10)
                            Text(tag.name)
                                .font(.system(size: 12))
                                .foregroundStyle(VoomTheme.textPrimary)
                            Spacer()
                            Button {
                                store.deleteTag(tag)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(VoomTheme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }

            Divider()

            // New tag
            HStack(spacing: 8) {
                TextField("Tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)

                HStack(spacing: 4) {
                    ForEach(Self.colorPresets, id: \.0) { hex, _ in
                        Circle()
                            .fill(Color(hex: hex) ?? .blue)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white, lineWidth: selectedColor == hex ? 2 : 0)
                            )
                            .onTapGesture { selectedColor = hex }
                    }
                }

                Button("Add") {
                    let tag = RecordingTag(name: newTagName, colorHex: selectedColor)
                    store.addTag(tag)
                    newTagName = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(VoomTheme.spacingXL)
        .frame(width: 420)
    }
}
