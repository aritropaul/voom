import SwiftUI

struct AnnotationToolbar: View {
    @Bindable var viewModel: AnnotationViewModel
    let presetColors: [Color]

    private let toolIcons: [(AnnotationTool, String)] = [
        (.freehand, "pencil.tip"),
        (.arrow, "arrow.up.right"),
        (.rectangle, "rectangle"),
        (.circle, "circle"),
        (.text, "textformat"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            // Tool buttons
            ForEach(toolIcons, id: \.0) { tool, icon in
                Button {
                    viewModel.currentTool = tool
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(viewModel.currentTool == tool ? .white : VoomTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(viewModel.currentTool == tool ? VoomTheme.borderMedium : Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 20)
                .overlay(VoomTheme.borderSubtle)

            // Color palette
            ForEach(Array(presetColors.enumerated()), id: \.offset) { _, color in
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .strokeBorder(.white, lineWidth: viewModel.currentColor == color ? 2 : 0)
                    )
                    .onTapGesture { viewModel.currentColor = color }
            }

            Divider()
                .frame(height: 20)
                .overlay(VoomTheme.borderSubtle)

            // Undo
            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12))
                    .foregroundStyle(VoomTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.shapes.isEmpty)

            // Clear
            Button {
                viewModel.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(VoomTheme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.shapes.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.45))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}
