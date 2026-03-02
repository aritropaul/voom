import SwiftUI

struct StitchSheet: View {
    let recordings: [Recording]
    @Binding var isPresented: Bool
    let onStitch: ([Recording]) -> Void

    @State private var orderedRecordings: [Recording] = []

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            Text("Stitch Recordings")
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)

            Text("Drag to reorder. Recordings will be combined in this order.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)

            List {
                ForEach(orderedRecordings) { recording in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12))
                            .foregroundStyle(VoomTheme.textTertiary)

                        if let thumbURL = recording.thumbnailURL,
                           let nsImage = NSImage(contentsOf: thumbURL) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(VoomTheme.textPrimary)
                                .lineLimit(1)
                            Text(formatDuration(recording.duration))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(VoomTheme.textTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in
                    orderedRecordings.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(orderedRecordings.count) * 52, 300))

            HStack {
                Text("Total: \(formatDuration(totalDuration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VoomTheme.textSecondary)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(VoomTheme.textSecondary)

                Button("Stitch") {
                    onStitch(orderedRecordings)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(VoomTheme.spacingXL)
        .frame(width: 400)
        .onAppear {
            orderedRecordings = recordings.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private var totalDuration: TimeInterval {
        orderedRecordings.reduce(0) { $0 + $1.duration }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }
}
