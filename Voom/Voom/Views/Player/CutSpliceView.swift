import SwiftUI
import AVFoundation
import CoreMedia

struct CutRegion: Identifiable {
    let id = UUID()
    var start: TimeInterval
    var end: TimeInterval
}

struct CutSpliceView: View {
    let videoURL: URL
    let duration: TimeInterval
    @Binding var cutRegions: [CutRegion]
    let onApply: ([CutRegion]) -> Void
    let onCancel: () -> Void

    @State private var newCutStart: TimeInterval = 0
    @State private var newCutEnd: TimeInterval = 5

    private let barHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: VoomTheme.spacingSM) {
            HStack {
                Text("Cut Sections")
                    .font(VoomTheme.fontHeadline())
                    .foregroundStyle(VoomTheme.textPrimary)
                Spacer()
                Text("\(cutRegions.count) cut\(cutRegions.count == 1 ? "" : "s")")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)
            }

            // Timeline bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background bar
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium)
                        .fill(VoomTheme.backgroundTertiary)
                        .frame(height: barHeight)

                    // Cut regions
                    ForEach(cutRegions) { region in
                        let startFrac = CGFloat(region.start / duration)
                        let endFrac = CGFloat(region.end / duration)
                        Rectangle()
                            .fill(VoomTheme.accentRed.opacity(0.4))
                            .frame(width: (endFrac - startFrac) * geo.size.width, height: barHeight)
                            .offset(x: startFrac * geo.size.width)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(VoomTheme.accentRed, lineWidth: 1)
                                    .frame(width: (endFrac - startFrac) * geo.size.width, height: barHeight)
                                    .offset(x: startFrac * geo.size.width),
                                alignment: .leading
                            )
                    }
                }
            }
            .frame(height: barHeight)
            .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusMedium))

            // Cut region list
            if !cutRegions.isEmpty {
                VStack(spacing: 4) {
                    ForEach(cutRegions) { region in
                        HStack {
                            Image(systemName: "scissors")
                                .font(.system(size: 10))
                                .foregroundStyle(VoomTheme.accentRed)
                            Text("\(formatTime(region.start)) – \(formatTime(region.end))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(VoomTheme.textSecondary)
                            Spacer()
                            Button {
                                cutRegions.removeAll { $0.id == region.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(VoomTheme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }

            // Add cut region
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("From")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                    TextField("0:00", value: $newCutStart, format: .number)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                }
                HStack(spacing: 4) {
                    Text("To")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                    TextField("0:05", value: $newCutEnd, format: .number)
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                }

                Button("Add Cut") {
                    let region = CutRegion(
                        start: max(0, min(newCutStart, duration)),
                        end: max(newCutStart + 0.1, min(newCutEnd, duration))
                    )
                    cutRegions.append(region)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newCutStart >= newCutEnd)

                Spacer()
            }

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoomTheme.textSecondary)
                Spacer()
                Button("Apply Cuts") {
                    onApply(cutRegions)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(cutRegions.isEmpty)
            }
        }
        .padding(VoomTheme.spacingLG)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .fill(VoomTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
