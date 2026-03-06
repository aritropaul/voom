import SwiftUI
import AVFoundation
import AVKit
import os
import VoomCore

private let playerLogger = Logger(subsystem: "com.voom.app", category: "Player")

private nonisolated(unsafe) let playerDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

private nonisolated(unsafe) let playerFileSizeFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB]
    return f
}()

struct PlayerView: View {
    let recordingID: UUID
    let topContentInset: CGFloat
    let topChromeHeight: CGFloat
    let showsVideoBorder: Bool
    let headerContent: AnyView?
    let onScrollStateChange: ((Bool) -> Void)?
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
    @State private var isEditingSummary = false
    @FocusState private var isSummaryFocused: Bool
    @State private var showTrimView = false
    @State private var showCutView = false
    @State private var showFillerSheet = false
    @State private var showStitchSheet = false
    @State private var showSharePasswordPopover = false
    @State private var isExportingGIF = false
    @State private var showAddTag = false
    @State private var showUnshareConfirmation = false
    @State private var newTagName = ""
    @State private var newTagColor = "5E5CE6"
    @State private var trimStart: TimeInterval = 0
    @State private var trimEnd: TimeInterval = 0
    @State private var cutRegions: [CutRegion] = []

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    init(
        recordingID: UUID,
        topContentInset: CGFloat = 56,
        topChromeHeight: CGFloat = 56,
        showsVideoBorder: Bool = true,
        headerContent: AnyView? = nil,
        onScrollStateChange: ((Bool) -> Void)? = nil
    ) {
        self.recordingID = recordingID
        self.topContentInset = topContentInset
        self.topChromeHeight = topChromeHeight
        self.showsVideoBorder = showsVideoBorder
        self.headerContent = headerContent
        self.onScrollStateChange = onScrollStateChange
    }

    private var recording: Recording? {
        store.recording(for: recordingID)
    }

    private var videoAspectRatio: CGFloat {
        guard let recording, recording.width > 0, recording.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(recording.width) / CGFloat(recording.height)
    }

    @ViewBuilder
    private func mainContent(outerProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            videoPlayer
                .id("video-player")
                .padding(.horizontal, VoomTheme.spacingXL)
                .padding(.top, VoomTheme.spacingXL)
                .staggeredAppear(0)

            actionBar
                .padding(.horizontal, VoomTheme.spacingXL)
                .padding(.top, VoomTheme.spacingSM)
                .staggeredAppear(1)

            if let recording {
                detailsSection(recording: recording)
                    .padding(.horizontal, VoomTheme.spacingXL)
                    .padding(.top, VoomTheme.spacingLG)
                    .staggeredAppear(2)
            }

            editingSection

            if let recording, let summary = recording.summary, !summary.isEmpty {
                summarySection(summary: summary)
                    .padding(.horizontal, VoomTheme.spacingXL)
                    .padding(.top, VoomTheme.spacingLG)
                    .staggeredAppear(3)
            }

            if let recording {
                ChapterView(
                    chapters: Binding(
                        get: { store.recording(for: recordingID)?.chapters ?? [] },
                        set: { newChapters in
                            if var rec = store.recording(for: recordingID) {
                                rec.chapters = newChapters
                                store.update(rec)
                            }
                        }
                    ),
                    currentTime: currentTime,
                    onSeek: { time in
                        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                    },
                    transcriptSegments: recording.transcriptSegments
                )
                .padding(.horizontal, VoomTheme.spacingXL)
                .padding(.top, VoomTheme.spacingLG)
                .staggeredAppear(4)
            }

            transcriptSection(scrollToVideo: {
                withAnimation(.smooth(duration: 0.3)) {
                    outerProxy.scrollTo("video-player", anchor: .top)
                }
            })
                .padding(.horizontal, VoomTheme.spacingXL)
                .padding(.top, VoomTheme.spacingLG)
                .padding(.bottom, VoomTheme.spacingXXL)
                .staggeredAppear(6)
        }
    }

    @ViewBuilder
    private var editingSection: some View {
        if let recording {
            editingToolsBar(recording: recording)
                .padding(.horizontal, VoomTheme.spacingXL)
                .padding(.top, VoomTheme.spacingSM)
        }
        if showTrimView, let recording {
            TrimView(
                videoURL: recording.fileURL,
                duration: recording.duration,
                startTime: $trimStart,
                endTime: $trimEnd,
                onApply: { start, end in
                    Task {
                        await applyTrim(recording: recording, start: start, end: end)
                    }
                    showTrimView = false
                },
                onCancel: { showTrimView = false }
            )
            .padding(.horizontal, VoomTheme.spacingXL)
            .padding(.top, VoomTheme.spacingSM)
            .onAppear {
                trimStart = 0
                trimEnd = recording.duration
            }
        }
        if showCutView, let recording {
            CutSpliceView(
                videoURL: recording.fileURL,
                duration: recording.duration,
                cutRegions: $cutRegions,
                onApply: { regions in
                    Task {
                        await applyCut(recording: recording, regions: regions)
                    }
                    showCutView = false
                },
                onCancel: { showCutView = false }
            )
            .padding(.horizontal, VoomTheme.spacingXL)
            .padding(.top, VoomTheme.spacingSM)
            .onAppear { cutRegions = [] }
        }
    }

    var body: some View {
        let usesEmbeddedHeader = headerContent != nil

        ZStack(alignment: .top) {
            ScrollViewReader { outerProxy in
                ScrollView {
                    mainContent(outerProxy: outerProxy)
                        .padding(.top, usesEmbeddedHeader ? 0 : topContentInset)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let headerContent {
                        headerContent
                    }
                }
                .background(.clear)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > (usesEmbeddedHeader ? 0 : topContentInset) + VoomTheme.spacingXL - 0.5
                } action: { _, isScrolled in
                    onScrollStateChange?(isScrolled)
                }
                .onTapGesture {
                    // Clicking outside text fields dismisses focus and commits edits
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    commitTitle()
                    commitSummary()
                }
            }

            if topChromeHeight > 0 && !usesEmbeddedHeader {
                VoomTheme.backgroundPrimary
                    .frame(height: topChromeHeight)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            onScrollStateChange?(false)
            setupPlayer()
            if let recording {
                editingTitle = recording.title
                editingSummary = recording.summary ?? ""
            }
        }
        .onDisappear {
            onScrollStateChange?(false)
            commitSummary()
            teardownPlayer()
        }
        .onChange(of: recording?.title) { _, newTitle in
            if let newTitle { editingTitle = newTitle }
        }
        .onChange(of: recording?.summary) { _, newSummary in
            editingSummary = newSummary ?? ""
            isEditingSummary = false
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
                NativePlayerView(player: player, wrapper: $playerWrapperRef, chapters: recording?.chapters ?? [])
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
        .overlay {
            if showsVideoBorder {
                RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                    .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        if let recording {
            HStack(spacing: 6) {
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
                    ActionBarButton(icon: "text.bubble", label: "Transcribe") {
                        Task { await transcribe(recording) }
                    }
                }

                // Captions toggle
                if recording.isTranscribed {
                    ActionBarButton(
                        icon: showCaptions ? "captions.bubble.fill" : "captions.bubble",
                        isActive: showCaptions
                    ) { showCaptions.toggle() }
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
                        .foregroundStyle(playbackSpeed != 1.0 ? Color.white : VoomTheme.textSecondary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VoomTheme.backgroundCard)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Playback Speed")

                // Upload progress indicator
                if uploadTracker.isUploading(recording.id) {
                    ProgressView(value: uploadTracker.progress(for: recording.id) ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 28, height: 28)
                }
            }
            .animation(.smooth(duration: 0.25), value: recording.isTranscribing)
        }
    }

    // MARK: - Details Section

    @ViewBuilder
    private func detailsSection(recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingMD) {
            TextField("Title", text: $editingTitle, axis: .vertical)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VoomTheme.textPrimary)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .onSubmit { commitTitle() }

            FlowLayout(spacing: VoomTheme.spacingMD) {
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

            FlowLayout(spacing: VoomTheme.spacingSM) {
                if recording.isTranscribed {
                    VoomBadge("Transcribed", color: VoomTheme.accentGreen, icon: "checkmark")
                } else if recording.isTranscribing {
                    VoomBadge("Transcribing", color: VoomTheme.accentOrange, icon: "arrow.triangle.2.circlepath")
                }

                // Assigned tag badges
                ForEach(recording.tags ?? []) { tag in
                    VoomBadge(tag.name, color: Color(hex: tag.colorHex) ?? .gray, icon: "tag.fill")
                }

                // Add tag button
                Button { showAddTag.toggle() } label: {
                    VoomBadge("Tag", color: VoomTheme.textTertiary, icon: "plus")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAddTag, arrowEdge: .bottom) {
                    tagPopoverContent(recording: recording)
                }
            }
        }
        .padding(VoomTheme.spacingLG)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voomCard()
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
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
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
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
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
                        .padding(.vertical, VoomTheme.spacingLG)
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
                        .padding(.vertical, VoomTheme.spacingLG)
                    }
                }
                .voomCard()
            }
        }
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
            playerLogger.error("[Voom] Manual transcription failed: \(error)")
        }
        updated.isTranscribing = false
        store.update(updated)
    }

    // MARK: - Summary Section

    @ViewBuilder
    private func summarySection(summary: String) -> some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            HStack {
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isSummaryExpanded {
                    Button {
                        if isEditingSummary {
                            commitSummary()
                            isEditingSummary = false
                        } else {
                            editingSummary = summary
                            isEditingSummary = true
                        }
                    } label: {
                        Image(systemName: isEditingSummary ? "checkmark.circle.fill" : "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(isEditingSummary ? VoomTheme.accentGreen : VoomTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isSummaryExpanded {
                if isEditingSummary {
                    TextEditor(text: $editingSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(VoomTheme.textSecondary)
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, VoomTheme.spacingLG - 5)
                        .padding(.vertical, VoomTheme.spacingMD)
                        .frame(minHeight: 120, maxHeight: 300)
                        .voomCard()
                        .focused($isSummaryFocused)
                        .onAppear { isSummaryFocused = true }
                        .onChange(of: isSummaryFocused) { _, focused in
                            if !focused {
                                commitSummary()
                                isEditingSummary = false
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(VoomTheme.textSecondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, VoomTheme.spacingLG)
                        .padding(.vertical, VoomTheme.spacingMD)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .voomCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Editing Tools Bar

    @ViewBuilder
    private func editingToolsBar(recording: Recording) -> some View {
        HStack(spacing: 6) {
            Spacer()

            ToolPillButton(
                icon: "scissors",
                label: "Trim",
                isActive: showTrimView
            ) {
                showTrimView.toggle()
                showCutView = false
            }

            ToolPillButton(
                icon: "rectangle.split.3x1",
                label: "Cut",
                isActive: showCutView
            ) {
                showCutView.toggle()
                showTrimView = false
            }

            if recording.isTranscribed {
                ToolPillButton(
                    icon: "wand.and.stars",
                    label: "Remove Fillers"
                ) {
                    showFillerSheet = true
                }
                .sheet(isPresented: $showFillerSheet) {
                    FillerWordSheet(recordingID: recording.id, isPresented: $showFillerSheet)
                }
            }

            if isExportingGIF {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 28, height: 28)
            } else {
                ToolPillButton(
                    icon: "photo.on.rectangle.angled",
                    label: "GIF"
                ) {
                    isExportingGIF = true
                    Task {
                        await exportGIF(recording)
                        isExportingGIF = false
                    }
                }
            }

            ToolPillButton(
                icon: "square.and.arrow.up",
                label: "Share",
                isActive: recording.isShared && !recording.isShareExpired
            ) {
                showSharePasswordPopover.toggle()
            }
            .sheet(isPresented: $showSharePasswordPopover) {
                ShareSettingsSheet(
                    recording: recording,
                    isPresented: $showSharePasswordPopover
                )
                .environment(store)
            }

            Spacer()
        }
    }

    // shareSettingsPopover removed — replaced by ShareSettingsSheet

    // MARK: - Tag Popover

    private static let tagColors = [
        ("5E5CE6", "Indigo"),
        ("BF5AF2", "Purple"),
        ("FF375F", "Pink"),
        ("64D2FF", "Teal"),
        ("30D158", "Green"),
        ("FF9F0A", "Orange"),
        ("FFD60A", "Yellow"),
        ("AC8E68", "Brown"),
    ]

    @ViewBuilder
    private func tagPopoverContent(recording: Recording) -> some View {
        let tags = recording.tags ?? []
        let allTags = store.availableTags

        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            // Assigned tags (removable)
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .gray)
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                                .font(.system(size: 11))
                                .foregroundStyle(VoomTheme.textPrimary)
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(VoomTheme.textTertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill((Color(hex: tag.colorHex) ?? .gray).opacity(0.15))
                        )
                        .overlay(Capsule().strokeBorder((Color(hex: tag.colorHex) ?? .gray).opacity(0.3), lineWidth: 0.5))
                        .onTapGesture {
                            var updated = recording
                            updated.tags = tags.filter { $0.id != tag.id }
                            store.update(updated)
                        }
                    }
                }

                Divider()
            }

            // Available tags to assign
            let unassigned = allTags.filter { tag in !tags.contains(where: { $0.id == tag.id }) }
            if !unassigned.isEmpty {
                ForEach(unassigned) { tag in
                    Button {
                        var updated = recording
                        var current = updated.tags ?? []
                        current.append(tag)
                        updated.tags = current
                        store.update(updated)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: tag.colorHex) ?? .gray)
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                                .font(.system(size: 12))
                                .foregroundStyle(VoomTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Divider()
            }

            // Create new tag
            HStack(spacing: 6) {
                TextField("New tag", text: $newTagName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(maxWidth: 120)
                    .onSubmit { createAndAssignTag(recording: recording) }

                HStack(spacing: 3) {
                    ForEach(Self.tagColors, id: \.0) { hex, _ in
                        Circle()
                            .fill(Color(hex: hex) ?? .blue)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle().strokeBorder(.white, lineWidth: newTagColor == hex ? 1.5 : 0)
                            )
                            .onTapGesture { newTagColor = hex }
                    }
                }

                Button {
                    createAndAssignTag(recording: recording)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(newTagName.trimmingCharacters(in: .whitespaces).isEmpty ? VoomTheme.textQuaternary : VoomTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(VoomTheme.spacingMD)
        .frame(width: 280)
    }

    private func createAndAssignTag(recording: Recording) {
        let name = newTagName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let tag = RecordingTag(name: name, colorHex: newTagColor)
        store.addTag(tag)
        var updated = recording
        var current = updated.tags ?? []
        current.append(tag)
        updated.tags = current
        store.update(updated)
        newTagName = ""
    }

    // MARK: - GIF Export

    private func exportGIF(_ recording: Recording) async {
        do {
            let data = try await GIFExporter.shared.exportGIF(
                from: recording.fileURL,
                startTime: 0,
                endTime: 15
            )
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .init("com.compuserve.gif"))
                toast.success("GIF copied to clipboard!", icon: "photo.on.rectangle.angled")
            }
        } catch {
            await MainActor.run {
                toast.error("GIF export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Trim & Cut

    private func applyTrim(recording: Recording, start: TimeInterval, end: TimeInterval) async {
        guard var rec = store.recording(for: recordingID) else { return }
        let storage = RecordingStorage.shared
        let outputURL = await storage.editedRecordingURL(for: rec.fileURL, suffix: "trimmed")
        do {
            try await VideoEditor.shared.trim(
                sourceURL: rec.fileURL,
                startTime: CMTime(seconds: start, preferredTimescale: 600),
                endTime: CMTime(seconds: end, preferredTimescale: 600),
                outputURL: outputURL
            )
            try? FileManager.default.removeItem(at: rec.fileURL)
            try FileManager.default.moveItem(at: outputURL, to: rec.fileURL)
            rec.duration = await storage.videoDuration(at: rec.fileURL)
            rec.fileSize = await storage.fileSize(at: rec.fileURL)
            await MainActor.run { store.update(rec) }
        } catch {
            playerLogger.error("[Voom] Trim failed: \(error)")
        }
    }

    private func applyCut(recording: Recording, regions: [CutRegion]) async {
        guard var rec = store.recording(for: recordingID) else { return }
        let storage = RecordingStorage.shared
        let outputURL = await storage.editedRecordingURL(for: rec.fileURL, suffix: "cut")
        let removals = regions.map {
            CMTimeRange(
                start: CMTime(seconds: $0.start, preferredTimescale: 600),
                end: CMTime(seconds: $0.end, preferredTimescale: 600)
            )
        }
        do {
            try await VideoEditor.shared.cutSections(
                sourceURL: rec.fileURL,
                removals: removals,
                outputURL: outputURL
            )
            try? FileManager.default.removeItem(at: rec.fileURL)
            try FileManager.default.moveItem(at: outputURL, to: rec.fileURL)
            rec.duration = await storage.videoDuration(at: rec.fileURL)
            rec.fileSize = await storage.fileSize(at: rec.fileURL)
            if !rec.transcriptSegments.isEmpty {
                rec.transcriptSegments = await VideoEditor.shared.adjustTranscript(
                    segments: rec.transcriptSegments,
                    removals: removals
                )
            }
            await MainActor.run { store.update(rec) }
        } catch {
            playerLogger.error("[Voom] Cut failed: \(error)")
        }
    }

    // MARK: - Speed Label

    private func speedLabel(_ speed: Float) -> String {
        if speed == Float(Int(speed)) {
            return "\(Int(speed))x"
        }
        if speed == 0.25 { return "0.25x" }
        if speed == 0.5 { return "0.5x" }
        if speed == 0.75 { return "0.75x" }
        if speed == 1.25 { return "1.25x" }
        if speed == 1.5 { return "1.5x" }
        return String(format: "%.1f", speed) + "x"
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
        playerDateFormatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        playerFileSizeFormatter.string(fromByteCount: bytes)
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
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
        .padding(.horizontal, VoomTheme.spacingLG)
        .padding(.top, VoomTheme.spacingLG)
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
                    if editingSegmentID != nil {
                        commitSegmentEdit()
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
                .foregroundStyle(isActive ? Color.white : VoomTheme.textTertiary)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 2)

            RoundedRectangle(cornerRadius: 1)
                .fill(isActive ? Color.white : VoomTheme.borderMedium)
                .frame(width: 2)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 2) {
                if let speaker = segment.speaker {
                    Text(speaker)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white.opacity(0.7) : VoomTheme.textTertiary)
                }

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
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .fill(
                    isActive
                        ? Color.white.opacity(0.08)
                        : (isHovered ? VoomTheme.backgroundHover : Color.clear)
                )
        )
        .overlay(
            isActive
                ? RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
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
