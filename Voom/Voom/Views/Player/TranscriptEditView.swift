import SwiftUI
import AVFoundation
import CoreMedia
import os
import VoomCore

private let editLogger = Logger(subsystem: "com.voom.app", category: "TranscriptEdit")

struct TranscriptEditView: View {
    let recordingID: UUID
    @Environment(RecordingStore.self) private var store
    @Binding var isPresented: Bool
    @State private var selectedWords: Set<String> = []  // "segmentID:wordIndex"
    @State private var isProcessing = false
    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            HStack {
                Text("Edit Transcript")
                    .font(VoomTheme.fontTitle())
                    .foregroundStyle(VoomTheme.textPrimary)
                Spacer()
                if !selectedWords.isEmpty {
                    Text("\(selectedWords.count) words selected")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }

            Text("Tap words to select them for removal from the video.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let recording = store.recording(for: recordingID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: VoomTheme.spacingMD) {
                        ForEach(recording.transcriptSegments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(formatTimestamp(segment.startTime))
                                    .font(VoomTheme.fontMono())
                                    .foregroundStyle(VoomTheme.accentOrange)

                                WrappingHStack(segment: segment, selectedWords: $selectedWords)
                            }
                            .padding(.horizontal, VoomTheme.spacingSM)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 400)
                .background(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .fill(VoomTheme.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                )
            }

            HStack {
                if !selectedWords.isEmpty {
                    Button("Clear Selection") {
                        selectedWords.removeAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoomTheme.textSecondary)
                    .font(VoomTheme.fontCaption())
                }

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
                    showConfirmation = true
                } label: {
                    HStack(spacing: 5) {
                        if isProcessing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "scissors")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text("Remove Selected (\(selectedWords.count))")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selectedWords.isEmpty || isProcessing ? VoomTheme.textTertiary : VoomTheme.accentRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .fill(selectedWords.isEmpty || isProcessing ? VoomTheme.backgroundCard : VoomTheme.accentRed.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .strokeBorder(selectedWords.isEmpty || isProcessing ? VoomTheme.borderSubtle : VoomTheme.accentRed.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedWords.isEmpty || isProcessing)
            }
        }
        .padding(VoomTheme.spacingXL)
        .frame(width: 550)
        .frame(minHeight: 350)
        .background(VoomTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
        .alert("Remove Words from Video?", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await applyCuts() }
            }
        } message: {
            Text("This will cut \(selectedWords.count) words from the video. This cannot be undone.")
        }
    }

    private func applyCuts() async {
        guard let recording = store.recording(for: recordingID) else { return }
        isProcessing = true

        var selections: [WordSelection] = []
        for segment in recording.transcriptSegments {
            let words = segment.text.split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() {
                let key = "\(segment.id):\(index)"
                if selectedWords.contains(key) {
                    let timeRange = await TranscriptEditor.shared.estimateTimeRange(
                        segment: segment,
                        wordRange: index..<(index + 1)
                    )
                    selections.append(WordSelection(
                        segmentID: segment.id,
                        wordIndex: index,
                        word: word,
                        estimatedTimeRange: timeRange
                    ))
                }
            }
        }

        let removals = await TranscriptEditor.shared.selectionsToRemovals(selections)
        guard !removals.isEmpty else {
            isProcessing = false
            return
        }

        let storage = RecordingStorage.shared
        let outputURL = await storage.editedRecordingURL(for: recording.fileURL, suffix: "edited")

        do {
            try await VideoEditor.shared.cutSections(
                sourceURL: recording.fileURL,
                removals: removals,
                outputURL: outputURL
            )

            let adjustedSegments = await VideoEditor.shared.adjustTranscript(
                segments: recording.transcriptSegments,
                removals: removals
            )

            try FileManager.default.removeItem(at: recording.fileURL)
            try FileManager.default.moveItem(at: outputURL, to: recording.fileURL)

            var updated = recording
            updated.transcriptSegments = adjustedSegments
            let asset = AVURLAsset(url: recording.fileURL)
            if let duration = try? await asset.load(.duration) {
                updated.duration = CMTimeGetSeconds(duration)
            }
            updated.fileSize = await storage.fileSize(at: recording.fileURL)
            store.update(updated)

            editLogger.info("[Voom] Transcript edit: removed \(removals.count) sections")
            isPresented = false
        } catch {
            editLogger.error("[Voom] Transcript edit failed: \(error)")
        }

        isProcessing = false
    }

    private func formatTimestamp(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Word Flow Layout

private struct WrappingHStack: View {
    let segment: TranscriptEntry
    @Binding var selectedWords: Set<String>

    var body: some View {
        let words = segment.text.split(separator: " ").map(String.init)
        FlowLayout(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let key = "\(segment.id):\(index)"
                let isSelected = selectedWords.contains(key)
                Text(word)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : VoomTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? VoomTheme.accentRed.opacity(0.6) : Color.clear)
                    )
                    .onTapGesture {
                        if isSelected {
                            selectedWords.remove(key)
                        } else {
                            selectedWords.insert(key)
                        }
                    }
            }
        }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), offsets)
    }
}
