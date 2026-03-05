import SwiftUI
import CoreMedia
import os

private let fillerLogger = Logger(subsystem: "com.voom.app", category: "FillerWord")

struct FillerWordSheet: View {
    let recordingID: UUID
    @Environment(RecordingStore.self) private var store
    @Binding var isPresented: Bool
    @State private var detections: [FillerDetection] = []
    @State private var isProcessing = false
    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            HStack {
                Text("Filler Words")
                    .font(VoomTheme.fontTitle())
                    .foregroundStyle(VoomTheme.textPrimary)
                Spacer()
                if !detections.isEmpty {
                    Text("\(selectedCount) of \(detections.count) selected")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }

            if detections.isEmpty && !isProcessing {
                VoomEmptyState(
                    icon: "waveform",
                    title: "No Filler Words Found",
                    subtitle: "No common filler words detected in the transcript.",
                    iconSize: 48,
                    symbolSize: 20
                )
                .padding(.vertical, VoomTheme.spacingXL)
            } else if isProcessing {
                VStack(spacing: VoomTheme.spacingSM) {
                    ProgressView()
                        .tint(VoomTheme.textTertiary)
                    Text("Analyzing transcript...")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textSecondary)
                }
                .padding(.vertical, VoomTheme.spacingXL)
            } else {
                Text("Toggle individual filler words on or off. Only checked items will be cut when you apply.")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(detections.enumerated()), id: \.element.id) { index, detection in
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { detections[index].isSelected },
                                    set: { detections[index].isSelected = $0 }
                                ))
                                .toggleStyle(.checkbox)
                                .tint(VoomTheme.accentOrange)

                                Text(detection.word)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(detections[index].isSelected ? VoomTheme.accentOrange : VoomTheme.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(detections[index].isSelected
                                                ? VoomTheme.accentOrange.opacity(0.15)
                                                : VoomTheme.backgroundTertiary
                                            )
                                    )

                                Text(formatTime(detection.estimatedTimeRange.start.seconds))
                                    .font(VoomTheme.fontMono())
                                    .foregroundStyle(VoomTheme.textTertiary)

                                Spacer()
                            }
                            .padding(.horizontal, VoomTheme.spacingSM)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 300)
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
                if !detections.isEmpty {
                    Button("Select All") {
                        for i in detections.indices { detections[i].isSelected = true }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoomTheme.textSecondary)
                    .font(VoomTheme.fontCaption())

                    Button("Deselect All") {
                        for i in detections.indices { detections[i].isSelected = false }
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
                        Image(systemName: "scissors")
                            .font(.system(size: 10, weight: .medium))
                        Text("Remove Selected (\(selectedCount))")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selectedCount == 0 || isProcessing ? VoomTheme.textTertiary : VoomTheme.accentRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .fill(selectedCount == 0 || isProcessing ? VoomTheme.backgroundCard : VoomTheme.accentRed.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .strokeBorder(selectedCount == 0 || isProcessing ? VoomTheme.borderSubtle : VoomTheme.accentRed.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedCount == 0 || isProcessing)
            }
        }
        .padding(VoomTheme.spacingXL)
        .frame(width: 450)
        .frame(minHeight: 300)
        .background(VoomTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
        .task {
            await detectFillers()
        }
        .alert("Remove \(selectedCount) filler words?", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await removeFillers() }
            }
        } message: {
            Text("This will permanently cut the selected filler words from the video. This cannot be undone.")
        }
    }

    private var selectedCount: Int {
        detections.filter(\.isSelected).count
    }

    private func detectFillers() async {
        guard let recording = store.recording(for: recordingID) else { return }
        isProcessing = true
        let results = await FillerWordDetector.shared.detect(in: recording.transcriptSegments)
        detections = results
        isProcessing = false
    }

    private func removeFillers() async {
        guard var recording = store.recording(for: recordingID) else { return }
        isProcessing = true

        let selectedRemovals = detections
            .filter(\.isSelected)
            .map(\.estimatedTimeRange)

        let storage = RecordingStorage.shared
        let outputURL = await storage.editedRecordingURL(for: recording.fileURL, suffix: "nofiller")

        do {
            try await VideoEditor.shared.cutSections(
                sourceURL: recording.fileURL,
                removals: selectedRemovals,
                outputURL: outputURL
            )

            // Update transcript
            let adjustedSegments = await VideoEditor.shared.adjustTranscript(
                segments: recording.transcriptSegments,
                removals: selectedRemovals
            )

            // Replace file
            try? FileManager.default.removeItem(at: recording.fileURL)
            try FileManager.default.moveItem(at: outputURL, to: recording.fileURL)

            // Update metadata
            let newDuration = await storage.videoDuration(at: recording.fileURL)
            let newFileSize = await storage.fileSize(at: recording.fileURL)
            recording.duration = newDuration
            recording.fileSize = newFileSize
            recording.transcriptSegments = adjustedSegments
            store.update(recording)

            isPresented = false
        } catch {
            fillerLogger.error("[Voom] Filler removal failed: \(error)")
        }

        isProcessing = false
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
