import SwiftUI
import VoomCore

struct CreateFolderSheet: View {
    @Binding var isPresented: Bool
    var existingFolder: Folder?
    let onSave: (String, String?) -> Void

    @State private var name: String = ""
    @State private var selectedColor: String = "FF9F0A"

    private let colorPresets = [
        "FF9F0A", // Orange
        "FF375F", // Red
        "BF5AF2", // Purple
        "5E5CE6", // Indigo
        "64D2FF", // Cyan
        "30D158", // Green
        "FFD60A", // Yellow
        "AC8E68", // Brown
    ]

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            Text(existingFolder == nil ? "New Folder" : "Rename Folder")
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                ForEach(colorPresets, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex) ?? .orange)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(.white, lineWidth: selectedColor == hex ? 2 : 0)
                        )
                        .onTapGesture { selectedColor = hex }
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoomTheme.textSecondary)

                Spacer()

                Button(existingFolder == nil ? "Create" : "Save") {
                    onSave(name, selectedColor)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(VoomTheme.spacingXL)
        .frame(width: 320)
        .onAppear {
            if let folder = existingFolder {
                name = folder.name
                selectedColor = folder.colorHex ?? "FF9F0A"
            }
        }
    }
}
