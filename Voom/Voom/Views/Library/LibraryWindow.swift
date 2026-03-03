import SwiftUI

struct LibraryWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(RecordingStore.self) private var store
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText = ""
    @State private var didPickUpInitialSelection = false
    @State private var showDeleteConfirmation = false
    @State private var uploadTracker = ShareUploadTracker.shared
    @State private var toast = ToastManager.shared
    @State private var selectedFolderID: UUID?
    @State private var showCreateFolder = false
    @State private var showStitchSheet = false
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var showSettings = false

    private var filteredRecordings: [Recording] {
        var result = store.recordings.sorted { $0.createdAt > $1.createdAt }

        // Folder filter
        if let folderID = selectedFolderID {
            result = result.filter { $0.folderID == folderID }
        }

        // Tag filter
        if !selectedTagIDs.isEmpty {
            result = result.filter { recording in
                guard let tags = recording.tags else { return false }
                return !selectedTagIDs.isDisjoint(with: Set(tags.map(\.id)))
            }
        }

        // Search filter
        if !searchText.isEmpty {
            result = result.filter { recording in
                recording.title.localizedCaseInsensitiveContains(searchText) ||
                recording.transcriptSegments.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return result
    }

    private var selectedRecordings: [Recording] {
        selectedIDs.compactMap { id in store.recording(for: id) }
    }

    private var singleSelection: UUID? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    private var detailTitle: String {
        if let id = singleSelection, let rec = store.recording(for: id) {
            return rec.title
        }
        return ""
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
                .background(VoomTheme.backgroundSecondary)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            Group {
                if showSettings {
                    InlineSettingsView()
                } else {
                    detailContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VoomTheme.backgroundPrimary)
            .animation(.easeInOut(duration: 0.25), value: showSettings)
            .animation(.easeInOut(duration: 0.25), value: singleSelection)
        }
        .frame(minWidth: 900, minHeight: 540)
        .navigationTitle(showSettings ? "Settings" : detailTitle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar { toolbarItems }
        .alert(
            "Delete \(selectedRecordings.count) Recordings?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteSelected() }
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
                showSettings = false
            }
        }
        .onChange(of: selectedIDs) { _, newIDs in
            if !newIDs.isEmpty {
                showSettings = false
            }
        }
        .sheet(isPresented: $showCreateFolder) {
            CreateFolderSheet(isPresented: $showCreateFolder) { name, colorHex in
                store.addFolder(Folder(name: name, colorHex: colorHex))
            }
        }
        .sheet(isPresented: $showStitchSheet) {
            StitchSheet(recordings: selectedRecordings, isPresented: $showStitchSheet) { ordered in
                Task { await stitchRecordings(ordered) }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            shareLinkToolbarContent
        }
        ToolbarItem(placement: .primaryAction) {
            shareFileToolbarContent
        }
        ToolbarItem(placement: .primaryAction) {
            stitchToolbarContent
        }
        ToolbarItem(placement: .primaryAction) {
            revealToolbarContent
        }
        ToolbarItem(placement: .destructiveAction) {
            deleteToolbarContent
        }
    }

    @ViewBuilder
    private var shareLinkToolbarContent: some View {
        if let rec = selectedRecordings.first, selectedIDs.count == 1 {
            if uploadTracker.isUploading(rec.id) {
                ProgressView(value: uploadTracker.progress(for: rec.id) ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("Uploading...")
            } else if rec.isShared && !rec.isShareExpired {
                Button { copyShareLink(rec) } label: {
                    Label("Copy Link", systemImage: "link")
                }
                .help(rec.shareExpiryDescription ?? "Copy share link")
                Button(role: .destructive) { removeShareLink(rec) } label: {
                    Label("Unshare", systemImage: "xmark.circle.fill")
                }
                .help("Remove shared link")
            } else {
                Button { shareViaLink(rec) } label: {
                    Label("Share via Link", systemImage: "link.badge.plus")
                }
                .help("Upload and get a shareable link")
            }
        }
    }

    @ViewBuilder
    private var shareFileToolbarContent: some View {
        if !selectedIDs.isEmpty {
            let urls = selectedRecordings.map(\.fileURL)
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
        }
    }

    @ViewBuilder
    private var stitchToolbarContent: some View {
        if selectedIDs.count >= 2 {
            Button { showStitchSheet = true } label: {
                Label("Stitch", systemImage: "film.stack")
            }
            .help("Stitch selected recordings together")
        }
    }

    @ViewBuilder
    private var revealToolbarContent: some View {
        if let rec = selectedRecordings.first, selectedIDs.count == 1 {
            Button {
                NSWorkspace.shared.selectFile(rec.fileURL.path, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Reveal in Finder")
        }
    }

    @ViewBuilder
    private var deleteToolbarContent: some View {
        if !selectedIDs.isEmpty {
            let count = selectedIDs.count
            Button(role: .destructive) { promptDeleteSelected() } label: {
                Label(count > 1 ? "Delete \(count)" : "Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .help(count > 1 ? "Delete \(count) recordings" : "Delete recording")
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                sidebarSearchField

                sidebarFoldersSection
                    .padding(.top, 4)

                sidebarTagsSection

                Divider()
                    .foregroundStyle(VoomTheme.borderSubtle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filteredRecordings.isEmpty {
                            if searchText.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "video.slash")
                                        .font(.system(size: 12, weight: .light))
                                        .foregroundStyle(VoomTheme.textQuaternary)
                                    Text(selectedFolderID != nil ? "Empty folder" : "No recordings yet")
                                        .font(.system(size: 12))
                                        .foregroundStyle(VoomTheme.textTertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, VoomTheme.spacingLG)
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 12, weight: .light))
                                        .foregroundStyle(VoomTheme.textQuaternary)
                                    Text("No results for \"\(searchText)\"")
                                        .font(.system(size: 12))
                                        .foregroundStyle(VoomTheme.textTertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, VoomTheme.spacingLG)
                            }
                        } else {
                            if !searchText.isEmpty {
                                Text("\(filteredRecordings.count) results")
                                    .font(VoomTheme.fontCaption())
                                    .foregroundStyle(VoomTheme.textTertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            }
                            sidebarRecordingsSection
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 60)
                }
                .onDeleteCommand { promptDeleteSelected() }
            }

            sidebarSettingsRow
        }
    }

    @ViewBuilder
    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(VoomTheme.textTertiary)
            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sidebarSettingsRow: some View {
        Button {
            showSettings.toggle()
            if showSettings { selectedIDs.removeAll() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gear")
                    .font(.system(size: 12))
                    .foregroundStyle(VoomTheme.textTertiary)
                    .frame(width: 20, alignment: .center)
                Text("Settings")
                    .font(.system(size: 13, weight: showSettings ? .medium : .regular))
                    .foregroundStyle(showSettings ? VoomTheme.textPrimary : VoomTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var sidebarFoldersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Folders")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VoomTheme.textTertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)

            SidebarNavRow(
                icon: "tray.fill",
                iconColor: VoomTheme.textPrimary,
                title: "All Recordings",
                isSelected: selectedFolderID == nil && !showSettings
            ) {
                selectedFolderID = nil
                showSettings = false
            }

            ForEach(store.folders) { folder in
                SidebarNavRow(
                    icon: "folder.fill",
                    iconColor: Color(hex: folder.colorHex ?? "FF9F0A") ?? VoomTheme.accentOrange,
                    title: folder.name,
                    isSelected: selectedFolderID == folder.id && !showSettings,
                    badge: store.recordings(in: folder).count
                ) {
                    selectedFolderID = folder.id
                    showSettings = false
                }
                .contextMenu {
                    Button("Rename") { /* handled via sheet */ }
                    Button("Delete", role: .destructive) { store.deleteFolder(folder) }
                }
            }

            SidebarNavRow(
                icon: "plus",
                iconColor: VoomTheme.textTertiary,
                title: "New Folder",
                isSelected: false
            ) { showCreateFolder = true }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var sidebarTagsSection: some View {
        if !store.availableTags.isEmpty {
            TagFilterView(availableTags: store.availableTags, selectedTagIDs: $selectedTagIDs)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var sidebarRecordingsSection: some View {
        ForEach(groupedRecordings) { group in
            VStack(alignment: .leading, spacing: 2) {
                Text(group.key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VoomTheme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                ForEach(group.recordings) { recording in
                    let isSelected = selectedIDs.contains(recording.id)
                    RecordingRow(
                        recording: recording,
                        uploadProgress: uploadTracker.progress(for: recording.id)
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) {
                            if isSelected {
                                selectedIDs.remove(recording.id)
                            } else {
                                selectedIDs.insert(recording.id)
                            }
                        } else {
                            selectedIDs = [recording.id]
                        }
                    }
                    .contextMenu { recordingContextMenu(for: recording) }
                }
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
            VStack(spacing: VoomTheme.spacingMD) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(VoomTheme.textQuaternary)
                VStack(spacing: 4) {
                    Text("\(selectedIDs.count) Recordings Selected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VoomTheme.textSecondary)
                    Text("Use the toolbar to share or delete.")
                        .font(.system(size: 12))
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }
            .staggeredAppear(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: VoomTheme.spacingMD) {
                HStack(spacing: VoomTheme.spacingSM) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 16, weight: .light))
                    Image(systemName: "waveform")
                        .font(.system(size: 16, weight: .light))
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .light))
                }
                .foregroundStyle(VoomTheme.textQuaternary)
                VStack(spacing: 4) {
                    Text("Select a Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VoomTheme.textSecondary)
                    Text("Choose a recording from the sidebar.")
                        .font(.system(size: 12))
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }
            .staggeredAppear(0)
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

        if recording.isTranscribed && !recording.transcriptSegments.isEmpty {
            Button {
                regenerateTitleAndSummary(recording)
            } label: {
                Label("Regenerate Title & Summary", systemImage: "sparkles")
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

        // Move to Folder
        if !store.folders.isEmpty {
            Menu("Move to Folder") {
                Button("None") {
                    var updated = recording
                    updated.folderID = nil
                    store.update(updated)
                }
                Divider()
                ForEach(store.folders) { folder in
                    Button(folder.name) {
                        var updated = recording
                        updated.folderID = folder.id
                        store.update(updated)
                    }
                }
            }
        }

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

    private func stitchRecordings(_ recordings: [Recording]) async {
        let storage = RecordingStorage.shared
        let outputURL = await storage.newRecordingURL()
        let sourceURLs = recordings.map(\.fileURL)
        do {
            try await VideoEditor.shared.stitch(sourceURLs: sourceURLs, outputURL: outputURL)
            let duration = await storage.videoDuration(at: outputURL)
            let resolution = await storage.videoResolution(at: outputURL)
            let fileSize = await storage.fileSize(at: outputURL)
            var recording = Recording(
                title: "Stitched Recording",
                fileURL: outputURL,
                duration: duration,
                fileSize: fileSize,
                width: resolution.width,
                height: resolution.height,
                hasWebcam: false,
                hasSystemAudio: true,
                hasMicAudio: true
            )
            let thumbURL = await storage.generateThumbnail(for: outputURL, recordingID: recording.id)
            recording.thumbnailURL = thumbURL
            await MainActor.run { store.add(recording) }
        } catch {
            NSLog("[Voom] Stitch failed: %@", "\(error)")
        }
    }

    private func regenerateTitleAndSummary(_ recording: Recording) {
        Task {
            let segments = recording.transcriptSegments
            let title = await TextAnalysisService.shared.generateTitle(from: segments)
            let summary = await TextAnalysisService.shared.generateSummary(from: segments)
            var updated = recording
            if !title.isEmpty {
                updated.title = title
            }
            updated.summary = summary.isEmpty ? nil : summary
            store.update(updated)
            if !title.isEmpty || !summary.isEmpty {
                toast.success("Title & summary regenerated", icon: "sparkles")
            } else {
                toast.error("Apple Intelligence unavailable on this device.")
            }
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
                toast.success("Uploaded & link copied!", icon: "link.badge.plus")
            } catch {
                toast.error("Share failed: \(error.localizedDescription)")
            }
        }
    }

    private func copyShareLink(_ recording: Recording) {
        guard let url = recording.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        toast.success("Link copied!")
    }

    private func renewShareLink(_ recording: Recording) {
        guard let code = recording.shareCode else { return }
        Task {
            do {
                let newExpiry = try await ShareService.shared.renew(shareCode: code)
                var updated = recording
                updated.shareExpiresAt = newExpiry
                store.update(updated)
                toast.success("Link renewed!", icon: "arrow.clockwise")
            } catch {
                toast.error("Renew failed: \(error.localizedDescription)")
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
                toast.success("Link removed", icon: "link.badge.plus")
            } catch {
                toast.error("Unshare failed: \(error.localizedDescription)")
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

// MARK: - Sidebar Navigation Row

struct SidebarNavRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let isSelected: Bool
    var badge: Int? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? VoomTheme.textPrimary : VoomTheme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(VoomTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.white.opacity(0.08)
        } else if isHovered {
            return Color.white.opacity(0.04)
        }
        return Color.clear
    }
}
