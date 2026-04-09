import SwiftUI
import AVFoundation
import os
import VoomCore

private let blurSheetLogger = Logger(subsystem: "com.voom.app", category: "PrivacyBlurSheet")

struct PrivacyBlurSheet: View {
    let recordingID: UUID
    @Environment(RecordingStore.self) private var store
    @Binding var isPresented: Bool
    @State private var regions: [BlurRegion] = []
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var currentFrame: CGImage?
    @State private var drawStart: CGPoint?
    @State private var drawEnd: CGPoint?
    @State private var videoSize: CGSize = .zero

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            HStack {
                Text("Privacy Blur")
                    .font(VoomTheme.fontTitle())
                    .foregroundStyle(VoomTheme.textPrimary)
                Spacer()
                if !regions.isEmpty {
                    Text("\(regions.count) region\(regions.count == 1 ? "" : "s")")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }

            Text("Draw rectangles on the video to blur regions. Drag to create a new region.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Video frame with drawing overlay
            ZStack {
                if let frame = currentFrame {
                    Image(decorative: frame, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay(blurRegionsOverlay)
                        .overlay(drawingOverlay)
                        .gesture(drawGesture)
                } else {
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .fill(VoomTheme.backgroundSecondary)
                        .frame(height: 280)
                        .overlay {
                            ProgressView()
                                .tint(VoomTheme.textTertiary)
                        }
                }
            }
            .frame(maxHeight: 320)

            // Regions list
            if !regions.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                            HStack(spacing: 8) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(VoomTheme.accentOrange)

                                Text("Region \(index + 1)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(VoomTheme.textPrimary)

                                Text(String(format: "%.0f%% × %.0f%%", region.rect.width * 100, region.rect.height * 100))
                                    .font(VoomTheme.fontMono())
                                    .foregroundStyle(VoomTheme.textTertiary)

                                Spacer()

                                Button {
                                    regions.remove(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(VoomTheme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, VoomTheme.spacingSM)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .fill(VoomTheme.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                )
            }

            // Progress bar
            if isProcessing {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .tint(VoomTheme.accentOrange)
                    Text("Applying blur... \(Int(progress * 100))%")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }

            // Action buttons
            HStack {
                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VoomTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                                .fill(VoomTheme.backgroundCard)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    Task { await applyBlur() }
                } label: {
                    HStack(spacing: 5) {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text("Apply Blur")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(regions.isEmpty || isProcessing ? VoomTheme.textTertiary : VoomTheme.accentOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .fill(regions.isEmpty || isProcessing ? VoomTheme.backgroundCard : VoomTheme.accentOrange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .strokeBorder(regions.isEmpty || isProcessing ? VoomTheme.borderSubtle : VoomTheme.accentOrange.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(regions.isEmpty || isProcessing)
            }
        }
        .padding(VoomTheme.spacingXL)
        .frame(width: 560)
        .frame(minHeight: 400)
        .background(VoomTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
        .task { await loadFrame() }
    }

    // MARK: - Overlays

    private var blurRegionsOverlay: some View {
        GeometryReader { geo in
            ForEach(regions) { region in
                let rect = region.rect.toCGRect(in: geo.size)
                Rectangle()
                    .strokeBorder(VoomTheme.accentRed, lineWidth: 2)
                    .background(VoomTheme.accentRed.opacity(0.15))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private var drawingOverlay: some View {
        GeometryReader { geo in
            if let start = drawStart, let end = drawEnd {
                let rect = normalizedDrawRect(start: start, end: end, in: geo.size)
                let pixelRect = rect.toCGRect(in: geo.size)
                Rectangle()
                    .strokeBorder(VoomTheme.accentOrange, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    .background(VoomTheme.accentOrange.opacity(0.1))
                    .frame(width: pixelRect.width, height: pixelRect.height)
                    .position(x: pixelRect.midX, y: pixelRect.midY)
            }
        }
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                drawStart = value.startLocation
                drawEnd = value.location
            }
            .onEnded { value in
                guard let imageSize = currentFrameDisplaySize else { return }
                let rect = normalizedDrawRect(start: value.startLocation, end: value.location, in: imageSize)
                if rect.width > 0.02 && rect.height > 0.02 {
                    regions.append(BlurRegion(rect: rect))
                }
                drawStart = nil
                drawEnd = nil
            }
    }

    private var currentFrameDisplaySize: CGSize? {
        guard currentFrame != nil else { return nil }
        // Approximate — in practice, this comes from the GeometryReader
        return CGSize(width: 560, height: 320)
    }

    // MARK: - Helpers

    private func normalizedDrawRect(start: CGPoint, end: CGPoint, in size: CGSize) -> NormalizedRect {
        let minX = min(start.x, end.x) / size.width
        let minY = min(start.y, end.y) / size.height
        let width = abs(end.x - start.x) / size.width
        let height = abs(end.y - start.y) / size.height
        return NormalizedRect(x: minX, y: minY, width: width, height: height)
    }

    private func loadFrame() async {
        guard let recording = store.recording(for: recordingID) else { return }
        let asset = AVURLAsset(url: recording.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1120, height: 640)

        do {
            let (image, _) = try await generator.image(at: .zero)
            currentFrame = image
        } catch {
            blurSheetLogger.error("[Voom] Failed to load frame: \(error)")
        }
    }

    private func applyBlur() async {
        guard let recording = store.recording(for: recordingID) else { return }
        isProcessing = true

        let storage = RecordingStorage.shared
        let outputURL = await storage.editedRecordingURL(for: recording.fileURL, suffix: "blurred")

        do {
            try await PrivacyBlurRenderer.shared.applyBlur(
                sourceURL: recording.fileURL,
                regions: regions,
                outputURL: outputURL,
                progress: { p in
                    Task { @MainActor in progress = p }
                }
            )

            try FileManager.default.removeItem(at: recording.fileURL)
            try FileManager.default.moveItem(at: outputURL, to: recording.fileURL)

            var updated = recording
            updated.blurRegions = regions
            updated.fileSize = await storage.fileSize(at: recording.fileURL)
            store.update(updated)

            blurSheetLogger.info("[Voom] Privacy blur applied: \(regions.count) regions")
            isPresented = false
        } catch {
            blurSheetLogger.error("[Voom] Privacy blur failed: \(error)")
        }

        isProcessing = false
    }
}
