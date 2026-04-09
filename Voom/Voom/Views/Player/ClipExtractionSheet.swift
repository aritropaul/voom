import SwiftUI
import CoreMedia
import os
import VoomCore

private let clipLogger = Logger(subsystem: "com.voom.app", category: "ClipExtraction")

struct ClipExtractionSheet: View {
    let recordingID: UUID
    @Environment(RecordingStore.self) private var store
    @Binding var isPresented: Bool
    @State private var suggestions: [ClipSuggestion] = []
    @State private var isLoading = false
    @State private var isExtracting = false

    var body: some View {
        VStack(spacing: VoomTheme.spacingLG) {
            HStack {
                Text("AI Clip Suggestions")
                    .font(VoomTheme.fontTitle())
                    .foregroundStyle(VoomTheme.textPrimary)
                Spacer()
                if !suggestions.isEmpty {
                    Text("\(selectedCount) of \(suggestions.count) selected")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }

            if suggestions.isEmpty && !isLoading {
                VoomEmptyState(
                    icon: "sparkles",
                    title: "No Clips Found",
                    subtitle: "AI couldn't identify key moments in this recording.",
                    iconSize: 48,
                    symbolSize: 20
                )
                .padding(.vertical, VoomTheme.spacingXL)
            } else if isLoading {
                VStack(spacing: VoomTheme.spacingSM) {
                    ProgressView()
                        .tint(VoomTheme.textTertiary)
                    Text("Analyzing transcript for key moments...")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textSecondary)
                }
                .padding(.vertical, VoomTheme.spacingXL)
            } else {
                Text("Select clips to extract as separate recordings.")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, clip in
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { suggestions[index].isSelected },
                                    set: { suggestions[index].isSelected = $0 }
                                ))
                                .toggleStyle(.checkbox)
                                .tint(VoomTheme.accentOrange)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(clip.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(suggestions[index].isSelected ? VoomTheme.textPrimary : VoomTheme.textTertiary)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text("\(formatTime(clip.startTime)) – \(formatTime(clip.endTime))")
                                            .font(VoomTheme.fontMono())
                                            .foregroundStyle(VoomTheme.textTertiary)

                                        Text("(\(formatDuration(clip.duration)))")
                                            .font(VoomTheme.fontMono())
                                            .foregroundStyle(VoomTheme.textQuaternary)
                                    }
                                }

                                Spacer()
                            }
                            .padding(.horizontal, VoomTheme.spacingSM)
                            .padding(.vertical, 6)
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
                if !suggestions.isEmpty {
                    Button("Select All") {
                        for i in suggestions.indices { suggestions[i].isSelected = true }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoomTheme.textSecondary)
                    .font(VoomTheme.fontCaption())

                    Button("Deselect All") {
                        for i in suggestions.indices { suggestions[i].isSelected = false }
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
                    Task { await extractClips() }
                } label: {
                    HStack(spacing: 5) {
                        if isExtracting {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "scissors")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text("Extract Selected (\(selectedCount))")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selectedCount == 0 || isExtracting ? VoomTheme.textTertiary : VoomTheme.accentOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .fill(selectedCount == 0 || isExtracting ? VoomTheme.backgroundCard : VoomTheme.accentOrange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .strokeBorder(selectedCount == 0 || isExtracting ? VoomTheme.borderSubtle : VoomTheme.accentOrange.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedCount == 0 || isExtracting)
            }
        }
        .padding(VoomTheme.spacingXL)
        .frame(width: 500)
        .frame(minHeight: 300)
        .background(VoomTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
        .task {
            await loadSuggestions()
        }
    }

    private var selectedCount: Int {
        suggestions.filter(\.isSelected).count
    }

    private func loadSuggestions() async {
        guard let recording = store.recording(for: recordingID) else { return }
        isLoading = true
        suggestions = await TextAnalysisService.shared.suggestClips(from: recording.transcriptSegments)
        isLoading = false
    }

    private func extractClips() async {
        guard let recording = store.recording(for: recordingID) else { return }
        isExtracting = true

        let selected = suggestions.filter(\.isSelected)
        let storage = RecordingStorage.shared

        for clip in selected {
            let outputURL = await storage.editedRecordingURL(for: recording.fileURL, suffix: "clip")
            do {
                let startCMTime = CMTime(seconds: clip.startTime, preferredTimescale: 600)
                let endCMTime = CMTime(seconds: clip.endTime, preferredTimescale: 600)
                try await VideoEditor.shared.trim(
                    sourceURL: recording.fileURL,
                    startTime: startCMTime,
                    endTime: endCMTime,
                    outputURL: outputURL
                )

                let duration = clip.duration
                let fileSize = await storage.fileSize(at: outputURL)

                var newRecording = Recording(
                    title: clip.title,
                    fileURL: outputURL,
                    duration: duration,
                    fileSize: fileSize,
                    width: recording.width,
                    height: recording.height,
                    hasWebcam: recording.hasWebcam,
                    hasSystemAudio: recording.hasSystemAudio,
                    hasMicAudio: recording.hasMicAudio
                )

                // Copy relevant transcript segments
                let clipSegments = recording.transcriptSegments.filter { seg in
                    seg.startTime >= clip.startTime && seg.endTime <= clip.endTime
                }.map { seg in
                    TranscriptEntry(
                        startTime: seg.startTime - clip.startTime,
                        endTime: seg.endTime - clip.startTime,
                        text: seg.text,
                        speaker: seg.speaker
                    )
                }
                newRecording.transcriptSegments = clipSegments
                newRecording.isTranscribed = !clipSegments.isEmpty

                if let thumbURL = await storage.generateThumbnail(for: outputURL, recordingID: newRecording.id) {
                    newRecording.thumbnailURL = thumbURL
                }
                store.add(newRecording)
            } catch {
                clipLogger.error("[Voom] Clip extraction failed: \(error)")
            }
        }

        isExtracting = false
        isPresented = false
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
