import SwiftUI
import AVFoundation

struct TrimView: View {
    let videoURL: URL
    let duration: TimeInterval
    @Binding var startTime: TimeInterval
    @Binding var endTime: TimeInterval
    let onApply: (TimeInterval, TimeInterval) -> Void
    let onCancel: () -> Void

    @State private var thumbnails: [NSImage] = []
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false

    private let thumbnailCount = 20
    private let handleWidth: CGFloat = 12
    private let barHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: VoomTheme.spacingSM) {
            HStack {
                Text("Trim")
                    .font(VoomTheme.fontHeadline())
                    .foregroundStyle(VoomTheme.textPrimary)
                Spacer()
                Text(formatRange)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(VoomTheme.textSecondary)
            }

            GeometryReader { geo in
                let totalWidth = geo.size.width - handleWidth * 2
                let startFraction = duration > 0 ? startTime / duration : 0
                let endFraction = duration > 0 ? endTime / duration : 1

                ZStack(alignment: .leading) {
                    // Thumbnail strip
                    HStack(spacing: 0) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: (totalWidth + handleWidth * 2) / CGFloat(max(thumbnails.count, 1)), height: barHeight)
                                .clipped()
                        }
                    }
                    .frame(height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusMedium))

                    // Dimmed before start
                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: handleWidth + CGFloat(startFraction) * totalWidth, height: barHeight)
                        .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusMedium))

                    // Dimmed after end
                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: handleWidth + (1 - CGFloat(endFraction)) * totalWidth, height: barHeight)
                        .offset(x: handleWidth + CGFloat(endFraction) * totalWidth)
                        .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusMedium))

                    // Selection border
                    let selectionX = handleWidth + CGFloat(startFraction) * totalWidth
                    let selectionW = CGFloat(endFraction - startFraction) * totalWidth
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(VoomTheme.accentOrange, lineWidth: 2)
                        .frame(width: selectionW, height: barHeight)
                        .offset(x: selectionX)

                    // Start handle
                    trimHandle(color: VoomTheme.accentOrange)
                        .offset(x: CGFloat(startFraction) * totalWidth)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let fraction = max(0, min(value.location.x / totalWidth, endTime / duration - 0.01))
                                    startTime = fraction * duration
                                }
                        )

                    // End handle
                    trimHandle(color: VoomTheme.accentOrange)
                        .offset(x: handleWidth + CGFloat(endFraction) * totalWidth)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let fraction = max(startTime / duration + 0.01, min(value.location.x / totalWidth, 1.0))
                                    endTime = fraction * duration
                                }
                        )
                }
            }
            .frame(height: barHeight)

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoomTheme.textSecondary)

                Spacer()

                Button("Apply Trim") {
                    onApply(startTime, endTime)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
        .onAppear {
            Task { await generateThumbnails() }
        }
    }

    private func trimHandle(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: handleWidth, height: barHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3, height: 20)
            )
            .cursor(.resizeLeftRight)
    }

    private var formatRange: String {
        "\(formatTime(startTime)) – \(formatTime(endTime)) (\(formatTime(endTime - startTime)))"
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func generateThumbnails() async {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)

        var images: [NSImage] = []
        for i in 0..<thumbnailCount {
            let time = CMTime(seconds: duration * Double(i) / Double(thumbnailCount), preferredTimescale: 600)
            do {
                let (cgImage, _) = try await generator.image(at: time)
                images.append(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            } catch {
                continue
            }
        }
        await MainActor.run { thumbnails = images }
    }
}

// MARK: - Cursor Helper

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
