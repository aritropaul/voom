import SwiftUI
import AVFoundation
import AVKit

struct PlayerView: View {
    let recordingID: UUID
    @Environment(RecordingStore.self) private var store
    @State private var player: AVPlayer?
    @State private var currentTime: TimeInterval = 0
    @State private var timeObserver: Any?
    @State private var isPlaying = false
    @State private var showCaptions = false
    @State private var playerWrapperRef: _PlayerWrapper?
    @State private var uploadTracker = ShareUploadTracker.shared
    @State private var toast = ToastManager.shared
    @State private var isSummaryExpanded = true
    @State private var playbackSpeed: Float = 1.0
    @State private var editingTitle: String = ""
    @State private var editingSummary: String = ""

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private var recording: Recording? {
        store.recording(for: recordingID)
    }

    private var videoAspectRatio: CGFloat {
        guard let recording, recording.width > 0, recording.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(recording.width) / CGFloat(recording.height)
    }

    var body: some View {
        ScrollViewReader { outerProxy in
        ScrollView {
            VStack(spacing: 0) {
                // Video player with native controls (fullscreen, PiP, volume built-in)
                videoPlayer
                    .id("video-player")
                    .padding(.horizontal, VoomTheme.spacingXL)
                    .padding(.top, VoomTheme.spacingXL)

                // Action bar (captions, transcribe, share)
                actionBar
                    .padding(.horizontal, VoomTheme.spacingXL)
                    .padding(.top, VoomTheme.spacingSM)

                // Details section
                if let recording {
                    detailsSection(recording: recording)
                        .padding(.horizontal, VoomTheme.spacingXL)
                        .padding(.top, VoomTheme.spacingLG)
                }

                // Summary section
                if let recording, let summary = recording.summary, !summary.isEmpty {
                    summarySection(summary: summary)
                        .padding(.horizontal, VoomTheme.spacingXL)
                        .padding(.top, VoomTheme.spacingLG)
                }

                // Transcript section
                transcriptSection(scrollToVideo: {
                    withAnimation(.smooth(duration: 0.3)) {
                        outerProxy.scrollTo("video-player", anchor: .top)
                    }
                })
                    .padding(.horizontal, VoomTheme.spacingXL)
                    .padding(.top, VoomTheme.spacingLG)
                    .padding(.bottom, VoomTheme.spacingXXL)
            }
        }
        }
        .onAppear {
            setupPlayer()
            if let recording {
                editingTitle = recording.title
                editingSummary = recording.summary ?? ""
            }
        }
        .onDisappear {
            commitSummary()
            teardownPlayer()
        }
        .onChange(of: recording?.title) { _, newTitle in
            if let newTitle { editingTitle = newTitle }
        }
        .onChange(of: recording?.summary) { _, newSummary in
            editingSummary = newSummary ?? ""
        }
        .onChange(of: showCaptions) { _, show in
            if !show { playerWrapperRef?.updateCaption(nil) }
        }
    }

    // MARK: - Video Player

    @ViewBuilder
    private var videoPlayer: some View {
        Group {
            if let player {
                NativePlayerView(player: player, wrapper: $playerWrapperRef)
            } else {
                VoomTheme.backgroundTertiary
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(VoomTheme.textQuaternary)
                    }
            }
        }
        .aspectRatio(videoAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        if let recording {
            HStack(spacing: 8) {
                Spacer()

                if recording.isTranscribing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Transcribing...")
                            .font(.caption)
                            .foregroundStyle(VoomTheme.textSecondary)
                    }
                    .transition(.opacity)
                } else if !recording.isTranscribed {
                    Button {
                        Task { await transcribe(recording) }
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 11))
                            .foregroundStyle(VoomTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Transcribe")
                }

                // Captions toggle
                if recording.isTranscribed {
                    Button {
                        showCaptions.toggle()
                    } label: {
                        Image(systemName: showCaptions ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 11))
                            .foregroundStyle(showCaptions ? Color.accentColor : VoomTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showCaptions ? "Hide Captions" : "Show Captions")
                }

                // Playback speed
                Menu {
                    ForEach(speeds, id: \.self) { speed in
                        Button {
                            playbackSpeed = speed
                            player?.rate = speed
                        } label: {
                            HStack {
                                Text(speedLabel(speed))
                                if speed == playbackSpeed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(speedLabel(playbackSpeed))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(playbackSpeed != 1.0 ? Color.accentColor : VoomTheme.textSecondary)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Playback Speed")

                // Share via Link
                if uploadTracker.isUploading(recording.id) {
                    ProgressView(value: uploadTracker.progress(for: recording.id) ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 28, height: 28)
                } else if recording.isShared && !recording.isShareExpired {
                    Button {
                        guard let url = recording.shareURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        toast.success("Link copied!")
                    } label: {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                            .foregroundStyle(VoomTheme.accentGreen)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(recording.shareExpiryDescription ?? "Copy share link")

                    Button {
                        Task { await removeShareLink(recording) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(VoomTheme.accentRed)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Unshare")
                } else {
                    Button {
                        Task { await shareViaLink(recording) }
                    } label: {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 11))
                            .foregroundStyle(VoomTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Share via Link")
                }

                ShareLink(item: recording.fileURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                        .foregroundStyle(VoomTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Share")
            }
            .animation(.smooth(duration: 0.25), value: recording.isTranscribing)
        }
    }

    // MARK: - Details Section

    @ViewBuilder
    private func detailsSection(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingMD) {
            TextField("Title", text: $editingTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(VoomTheme.textPrimary)
                .textFieldStyle(.plain)
                .onSubmit { commitTitle() }

            HStack(spacing: VoomTheme.spacingMD) {
                detailChip(icon: "calendar", text: formatDate(recording.createdAt))
                if recording.duration > 0 {
                    detailChip(icon: "clock", text: formatDuration(recording.duration))
                }
                if recording.width > 0 {
                    detailChip(icon: "rectangle.on.rectangle", text: "\(recording.width)×\(recording.height)")
                }
                if recording.fileSize > 0 {
                    detailChip(icon: "doc", text: formatFileSize(recording.fileSize))
                }
            }

            HStack(spacing: VoomTheme.spacingSM) {
                if recording.hasWebcam {
                    VoomBadge("Camera", color: VoomTheme.textSecondary, icon: "camera.fill")
                }
                if recording.hasMicAudio {
                    VoomBadge("Mic", color: VoomTheme.textSecondary, icon: "mic.fill")
                }
                if recording.hasSystemAudio {
                    VoomBadge("System Audio", color: VoomTheme.textSecondary, icon: "speaker.wave.2.fill")
                }
                if recording.isTranscribed {
                    VoomBadge("Transcribed", color: VoomTheme.accentGreen, icon: "checkmark")
                } else if recording.isTranscribing {
                    VoomBadge("Transcribing", color: VoomTheme.accentOrange, icon: "arrow.triangle.2.circlepath")
                }
            }
        }
        .padding(VoomTheme.spacingLG)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .fill(VoomTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
    }

    private func detailChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(VoomTheme.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(VoomTheme.textSecondary)
        }
    }

    // MARK: - Transcript Section

    @ViewBuilder
    private func transcriptSection(scrollToVideo: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recording {
                HStack {
                    VoomSectionHeader(
                        icon: "text.bubble",
                        title: "Transcript",
                        count: recording.transcriptSegments.isEmpty ? nil : recording.transcriptSegments.count
                    )
                    if !recording.isTranscribed && !recording.isTranscribing {
                        Spacer()
                        Button {
                            Task { await transcribe(recording) }
                        } label: {
                            Label("Transcribe", systemImage: "text.bubble")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, VoomTheme.spacingLG)
                .padding(.vertical, VoomTheme.spacingMD)

                if !recording.transcriptSegments.isEmpty {
                    TranscriptListView(
                        segments: recording.transcriptSegments.sorted { $0.startTime < $1.startTime },
                        currentTime: currentTime,
                        onSeek: { time in
                            player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                            scrollToVideo()
                        },
                        onUpdateSegment: { segmentID, newText in
                            updateSegmentText(segmentID: segmentID, newText: newText)
                        }
                    )
                } else if recording.isTranscribing {
                    HStack(spacing: VoomTheme.spacingSM) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing audio...")
                            .font(.system(size: 13))
                            .foregroundStyle(VoomTheme.textSecondary)
                    }
                    .padding(.horizontal, VoomTheme.spacingLG)
                    .padding(.bottom, VoomTheme.spacingLG)
                } else {
                    HStack(spacing: VoomTheme.spacingSM) {
                        Image(systemName: "waveform")
                            .font(.system(size: 14))
                            .foregroundStyle(VoomTheme.textTertiary)
                        Text("No transcript yet. Transcribe to see text alongside the video.")
                            .font(.system(size: 12))
                            .foregroundStyle(VoomTheme.textTertiary)
                    }
                    .padding(.horizontal, VoomTheme.spacingLG)
                    .padding(.bottom, VoomTheme.spacingLG)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .fill(VoomTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Editing

    private func commitTitle() {
        guard var rec = recording, !editingTitle.isEmpty, editingTitle != rec.title else { return }
        rec.title = editingTitle
        store.update(rec)
    }

    private func updateSegmentText(segmentID: UUID, newText: String) {
        guard var rec = recording else { return }
        if let idx = rec.transcriptSegments.firstIndex(where: { $0.id == segmentID }) {
            rec.transcriptSegments[idx].text = newText
            store.update(rec)
        }
    }

    private func commitSummary() {
        guard var rec = recording else { return }
        let trimmed = editingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSummary = trimmed.isEmpty ? nil : trimmed
        guard newSummary != rec.summary else { return }
        rec.summary = newSummary
        store.update(rec)
    }

    // MARK: - Player

    private func setupPlayer() {
        guard let recording else { return }
        let avPlayer = AVPlayer(url: recording.fileURL)
        self.player = avPlayer

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [self] time in
            MainActor.assumeIsolated {
                let t = time.seconds
                currentTime = t
                isPlaying = avPlayer.rate > 0

                // Re-apply playback speed if AVPlayer reset it on play
                if avPlayer.rate > 0 && avPlayer.rate != playbackSpeed {
                    avPlayer.rate = playbackSpeed
                }

                if showCaptions, let segments = store.recording(for: recordingID)?.transcriptSegments {
                    let caption = segments.first { t >= $0.startTime && t < $0.endTime }?.text
                    playerWrapperRef?.updateCaption(caption)
                }
            }
        }
    }

    private func teardownPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player?.pause()
        player = nil
        timeObserver = nil
    }

    private func shareViaLink(_ recording: Recording) async {
        do {
            let result = try await ShareService.shared.share(recording: recording)
            var updated = recording
            updated.shareURL = result.shareURL
            updated.shareCode = result.shareCode
            updated.shareExpiresAt = result.expiresAt
            store.update(updated)

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.shareURL.absoluteString, forType: .string)
            toast.success("Uploaded & link copied!", icon: "link.badge.plus")
        } catch {
            toast.error("Share failed: \(error.localizedDescription)")
        }
    }

    private func removeShareLink(_ recording: Recording) async {
        guard let code = recording.shareCode else { return }
        do {
            try await ShareService.shared.deleteShare(shareCode: code)
            var updated = recording
            updated.shareURL = nil
            updated.shareCode = nil
            updated.shareExpiresAt = nil
            store.update(updated)
            toast.success("Link removed", icon: "link.badge.plus")
        } catch {
            toast.error("Unshare failed: \(error.localizedDescription)")
        }
    }

    private func transcribe(_ recording: Recording) async {
        var updated = recording
        updated.isTranscribing = true
        store.update(updated)

        do {
            let voomSegments = try await TranscriptionService.shared.transcribe(audioURL: recording.fileURL)
            let entries = voomSegments.map {
                TranscriptEntry(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
            }
            updated.transcriptSegments = entries
            updated.isTranscribed = !voomSegments.isEmpty

            let generatedTitle = await TextAnalysisService.shared.generateTitle(from: entries)
            let generatedSummary = await TextAnalysisService.shared.generateSummary(from: entries)
            if !generatedTitle.isEmpty {
                updated.title = generatedTitle
            }
            updated.summary = generatedSummary.isEmpty ? nil : generatedSummary
        } catch {
            NSLog("[Voom] Manual transcription failed: %@", "\(error)")
        }
        updated.isTranscribing = false
        store.update(updated)
    }

    // MARK: - Summary Section

    @ViewBuilder
    private func summarySection(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    isSummaryExpanded.toggle()
                }
            } label: {
                HStack {
                    VoomSectionHeader(icon: "text.alignleft", title: "Summary")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VoomTheme.textTertiary)
                        .rotationEffect(.degrees(isSummaryExpanded ? 90 : 0))
                }
                .padding(.horizontal, VoomTheme.spacingLG)
                .padding(.vertical, VoomTheme.spacingMD)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSummaryExpanded {
                TextEditor(text: $editingSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(VoomTheme.textSecondary)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, VoomTheme.spacingLG - 5)
                    .padding(.bottom, VoomTheme.spacingLG)
                    .frame(minHeight: 60)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .fill(VoomTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Speed Label

    private func speedLabel(_ speed: Float) -> String {
        if speed == Float(Int(speed)) {
            return "\(Int(speed))x"
        }
        return "\(String(format: "%.2g", speed))x"
    }

    // MARK: - Formatters

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Transcript List

private struct TranscriptListView: View {
    let segments: [TranscriptEntry]
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    var onUpdateSegment: ((UUID, String) -> Void)?
    @State private var searchText = ""
    @State private var hoveredSegmentID: UUID?
    @State private var editingSegmentID: UUID?
    @State private var editingSegmentText: String = ""

    private var filteredSegments: [TranscriptEntry] {
        if searchText.isEmpty { return segments }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(VoomTheme.textTertiary)
            TextField("Search transcript...", text: $searchText)
                .textFieldStyle(.plain)
                .font(VoomTheme.fontBody())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .fill(VoomTheme.backgroundPrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
        .padding(.horizontal, VoomTheme.spacingLG)
        .padding(.bottom, VoomTheme.spacingSM)

        VStack(spacing: 2) {
            ForEach(filteredSegments) { segment in
                SegmentRow(
                    segment: segment,
                    isActive: isActive(segment),
                    isHovered: hoveredSegmentID == segment.id,
                    isEditing: editingSegmentID == segment.id,
                    editingText: editingSegmentID == segment.id ? $editingSegmentText : nil
                )
                .id(segment.id)
                .onTapGesture(count: 2) {
                    editingSegmentID = segment.id
                    editingSegmentText = segment.text
                }
                .onTapGesture(count: 1) {
                    if editingSegmentID == segment.id {
                        return
                    }
                    onSeek(segment.startTime)
                }
                .onHover { hovering in
                    hoveredSegmentID = hovering ? segment.id : nil
                }
            }
        }
        .onSubmit {
            commitSegmentEdit()
        }
        .padding(.horizontal, VoomTheme.spacingSM)
        .padding(.bottom, VoomTheme.spacingMD)
    }

    private func commitSegmentEdit() {
        guard let id = editingSegmentID else { return }
        let trimmed = editingSegmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onUpdateSegment?(id, trimmed)
        }
        editingSegmentID = nil
    }

    private func isActive(_ segment: TranscriptEntry) -> Bool {
        currentTime >= segment.startTime && currentTime < segment.endTime
    }
}

private struct SegmentRow: View {
    let segment: TranscriptEntry
    let isActive: Bool
    let isHovered: Bool
    var isEditing: Bool = false
    var editingText: Binding<String>?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(formatTimestamp(segment.startTime))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? Color.accentColor : VoomTheme.textTertiary)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 2)

            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? Color.accentColor : VoomTheme.borderMedium)
                .frame(width: 2)
                .padding(.vertical, 1)

            if isEditing, let editingText {
                TextField("", text: editingText)
                    .font(.system(size: 12))
                    .foregroundStyle(VoomTheme.textPrimary)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(segment.text)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? VoomTheme.textPrimary : VoomTheme.textSecondary)
                    .lineSpacing(2)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .fill(
                    isActive
                        ? Color.accentColor.opacity(0.08)
                        : (isHovered ? VoomTheme.backgroundHover : Color.clear)
                )
        )
        .overlay(
            isActive
                ? RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 0.5)
                : nil
        )
        .animation(.smooth(duration: 0.15), value: isActive)
        .animation(.smooth(duration: 0.1), value: isHovered)
        .contentShape(Rectangle())
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
