import SwiftUI

struct LibraryWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingStore.self) private var store
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var didPickUpInitialSelection = false
    @State private var showDeleteConfirmation = false
    @State private var uploadTracker = ShareUploadTracker.shared

    private var filteredRecordings: [Recording] {
        let sorted = store.recordings.sorted { $0.createdAt > $1.createdAt }
        if searchText.isEmpty { return sorted }
        return sorted.filter { recording in
            recording.title.localizedCaseInsensitiveContains(searchText) ||
            recording.transcriptSegments.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var selectedRecordings: [Recording] {
        selectedIDs.compactMap { id in store.recording(for: id) }
    }

    private var singleSelection: UUID? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    // MARK: - Date Grouping

    private struct RecordingGroup: Identifiable {
        let key: String
        let recordings: [Recording]
        var id: String { key }
    }

    private var groupedRecordings: [RecordingGroup] {
        let calendar = Calendar.current
        let now = Date()
        let groups = Dictionary(grouping: filteredRecordings) { recording -> String in
            let date = recording.createdAt
            if calendar.isDateInToday(date) {
                return "Today"
            } else if calendar.isDateInYesterday(date) {
                return "Yesterday"
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      date > weekAgo {
                return "This Week"
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
                      date > monthAgo {
                return "This Month"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM yyyy"
                return formatter.string(from: date)
            }
        }

        let order = ["Today", "Yesterday", "This Week", "This Month"]
        return groups.sorted { a, b in
            let aIdx = order.firstIndex(of: a.key) ?? Int.max
            let bIdx = order.firstIndex(of: b.key) ?? Int.max
            if aIdx != bIdx { return aIdx < bIdx }
            let aDate = a.value.first?.createdAt ?? .distantPast
            let bDate = b.value.first?.createdAt ?? .distantPast
            return aDate > bDate
        }.map { RecordingGroup(key: $0.key, recordings: $0.value) }
    }

    // MARK: - Stats

    private var totalDuration: TimeInterval {
        filteredRecordings.reduce(0) { $0 + $1.duration }
    }

    private var totalFileSize: Int64 {
        filteredRecordings.reduce(0) { $0 + $1.fileSize }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            detailContent
        }
        .searchable(text: $searchText, prompt: "Search recordings...")
        .frame(minWidth: 900, minHeight: 540)
        .navigationTitle("Voom")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !selectedIDs.isEmpty {
                    let selected = selectedRecordings
                    let urls = selected.map(\.fileURL)

                    // Share via Link
                    if selected.count == 1, let rec = selected.first {
                        if uploadTracker.isUploading(rec.id) {
                            ProgressView(value: uploadTracker.progress(for: rec.id) ?? 0)
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .help("Uploading...")
                        } else if rec.isShared && !rec.isShareExpired {
                            Button {
                                copyShareLink(rec)
                            } label: {
                                Label("Copy Link", systemImage: "link")
                            }
                            .help(rec.shareExpiryDescription ?? "Copy share link")
                        } else {
                            Button {
                                shareViaLink(rec)
                            } label: {
                                Label("Share via Link", systemImage: "link.badge.plus")
                            }
                            .help("Upload and get a shareable link")
                        }
                    }

                    if urls.count == 1, let url = urls.first {
                        ShareLink(item: url) {
                            Label("Share File", systemImage: "square.and.arrow.up")
                        }
                        .help("Share file")
                    } else if urls.count > 1 {
                        ShareLink(items: urls) { url in
                            SharePreview(url.lastPathComponent, image: Image(systemName: "video.fill"))
                        } label: {
                            Label("Share \(urls.count)", systemImage: "square.and.arrow.up")
                        }
                        .help("Share \(urls.count) recordings")
                    }

                    if selected.count == 1, let rec = selected.first {
                        Button {
                            NSWorkspace.shared.selectFile(rec.fileURL.path, inFileViewerRootedAtPath: "")
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .help("Reveal in Finder")
                    }

                    Button(role: .destructive) {
                        promptDeleteSelected()
                    } label: {
                        Label(
                            selected.count > 1 ? "Delete \(selected.count)" : "Delete",
                            systemImage: "trash"
                        )
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help(selected.count > 1 ? "Delete \(selected.count) recordings" : "Delete recording")
                }
            }
        }
        .alert(
            "Delete \(selectedRecordings.count) Recordings?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("This will permanently delete the selected recordings and their files.")
        }
        .onAppear {
            if !didPickUpInitialSelection, let id = appState.selectedRecordingID {
                selectedIDs = [id]
                appState.selectedRecordingID = nil
                didPickUpInitialSelection = true
            }
        }
        .onChange(of: appState.selectedRecordingID) { _, newID in
            if let newID {
                selectedIDs = [newID]
                appState.selectedRecordingID = nil
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        if filteredRecordings.isEmpty {
            VStack(spacing: 0) {
                Spacer()
                if searchText.isEmpty {
                    VoomEmptyState(
                        icon: "video.slash",
                        title: "No Recordings",
                        subtitle: "Record your first video from the menu bar."
                    )
                } else {
                    VoomEmptyState(
                        icon: "magnifyingglass",
                        title: "No Results",
                        subtitle: "No recordings match \"\(searchText)\"."
                    )
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $selectedIDs) {
                Section {
                    statsBar
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
                ForEach(groupedRecordings) { group in
                    Section {
                        ForEach(group.recordings) { recording in
                            RecordingRow(
                                recording: recording,
                                uploadProgress: uploadTracker.progress(for: recording.id)
                            )
                                .tag(recording.id)
                                .contextMenu {
                                    recordingContextMenu(for: recording)
                                }
                        }
                    } header: {
                        Text(group.key)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(VoomTheme.textTertiary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Recordings")
            .onDeleteCommand {
                promptDeleteSelected()
            }
        }
    }

    // MARK: - Stats Bar

    @ViewBuilder
    private var statsBar: some View {
        HStack(spacing: 12) {
            statChip(icon: "video.fill", text: "\(filteredRecordings.count)")
            statChip(icon: "clock.fill", text: formatTotalDuration(totalDuration))
            statChip(icon: "internaldrive.fill", text: formatFileSize(totalFileSize))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(VoomTheme.textTertiary)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let singleID = singleSelection {
            PlayerView(recordingID: singleID)
                .id(singleID)
        } else if selectedIDs.count > 1 {
            VoomEmptyState(
                icon: "rectangle.stack",
                title: "\(selectedIDs.count) Recordings Selected",
                subtitle: "Use the toolbar to share or delete the selected recordings."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VoomEmptyState(
                icon: "play.rectangle",
                title: "Select a Recording",
                subtitle: "Choose a recording from the sidebar to preview and play."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func recordingContextMenu(for recording: Recording) -> some View {
        // Share via Link
        if uploadTracker.isUploading(recording.id) {
            Label("Uploading...", systemImage: "arrow.up.circle")
                .disabled(true)
        } else if recording.isShared && !recording.isShareExpired {
            Button {
                copyShareLink(recording)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        } else {
            Button {
                shareViaLink(recording)
            } label: {
                Label("Share via Link", systemImage: "link.badge.plus")
            }
        }

        if recording.isShared {
            if recording.isShareExpired {
                Button {
                    renewShareLink(recording)
                } label: {
                    Label("Renew Link", systemImage: "arrow.clockwise")
                }
            } else if let desc = recording.shareExpiryDescription {
                Text(desc)
            }

            Button(role: .destructive) {
                removeShareLink(recording)
            } label: {
                Label("Remove Link", systemImage: "link.badge.plus")
            }
        }

        Divider()

        Button {
            NSWorkspace.shared.selectFile(recording.fileURL.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recording.fileURL.path, forType: .string)
        } label: {
            Label("Copy File Path", systemImage: "doc.on.doc")
        }
        ShareLink(item: recording.fileURL)
        Divider()
        Button(role: .destructive) {
            selectedIDs.remove(recording.id)
            store.delete(recording)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func deleteSelected() {
        let idsToDelete = Array(selectedIDs)
        selectedIDs.removeAll()
        for id in idsToDelete {
            if let recording = store.recording(for: id) {
                store.delete(recording)
            }
        }
    }

    private func promptDeleteSelected() {
        if selectedIDs.count > 1 {
            showDeleteConfirmation = true
        } else if !selectedIDs.isEmpty {
            deleteSelected()
        }
    }

    // MARK: - Share Actions

    private func shareViaLink(_ recording: Recording) {
        Task {
            do {
                let result = try await ShareService.shared.share(recording: recording)
                var updated = recording
                updated.shareURL = result.shareURL
                updated.shareCode = result.shareCode
                updated.shareExpiresAt = result.expiresAt
                store.update(updated)

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.shareURL.absoluteString, forType: .string)
            } catch {
                NSLog("[Voom] Share failed: %@", "\(error)")
            }
        }
    }

    private func copyShareLink(_ recording: Recording) {
        guard let url = recording.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func renewShareLink(_ recording: Recording) {
        guard let code = recording.shareCode else { return }
        Task {
            do {
                let newExpiry = try await ShareService.shared.renew(shareCode: code)
                var updated = recording
                updated.shareExpiresAt = newExpiry
                store.update(updated)
            } catch {
                NSLog("[Voom] Renew failed: %@", "\(error)")
            }
        }
    }

    private func removeShareLink(_ recording: Recording) {
        guard let code = recording.shareCode else { return }
        Task {
            do {
                try await ShareService.shared.deleteShare(shareCode: code)
                var updated = recording
                updated.shareURL = nil
                updated.shareCode = nil
                updated.shareExpiresAt = nil
                store.update(updated)
            } catch {
                NSLog("[Voom] Remove share failed: %@", "\(error)")
            }
        }
    }

    // MARK: - Formatters

    private func formatTotalDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let recording: Recording
    var uploadProgress: Double?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(VoomTheme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(relativeDate(recording.createdAt))
                    if recording.fileSize > 0 {
                        Text("·")
                        Text(formatFileSize(recording.fileSize))
                    }
                    if let progress = uploadProgress {
                        ProgressView(value: progress)
                            .controlSize(.mini)
                            .frame(width: 40)
                    } else if recording.isShared {
                        Image(systemName: "link")
                            .font(.system(size: 10))
                            .foregroundStyle(recording.isShareExpired ? VoomTheme.accentOrange : VoomTheme.accentGreen)
                    }
                    if recording.isTranscribing {
                        ProgressView()
                            .controlSize(.mini)
                    } else if recording.isTranscribed {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(VoomTheme.accentGreen)
                    }
                }
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textSecondary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbURL = recording.thumbnailURL,
               let nsImage = NSImage(contentsOf: thumbURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                            .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .fill(VoomTheme.backgroundTertiary)
                    .frame(width: 96, height: 58)
                    .overlay {
                        Image(systemName: "video.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(VoomTheme.textTertiary)
                    }
            }
            // Duration badge
            Text(formatDuration(recording.duration))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusSmall, style: .continuous)
                        .fill(.black.opacity(0.75))
                )
                .padding(3)
        }
    }

    @ViewBuilder
    private var sourceIcons: some View {
        HStack(spacing: 4) {
            if recording.hasWebcam {
                Image(systemName: "camera.fill")
            }
            if recording.hasMicAudio {
                Image(systemName: "mic.fill")
            }
            if recording.hasSystemAudio {
                Image(systemName: "speaker.wave.2.fill")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(VoomTheme.textTertiary)
    }

    @ViewBuilder
    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(VoomTheme.fontMono())
            .fontWeight(.medium)
            .foregroundStyle(VoomTheme.textTertiary)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
