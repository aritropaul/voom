import SwiftUI

struct ChapterView: View {
    @Binding var chapters: [Chapter]
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void
    var transcriptSegments: [TranscriptEntry] = []

    @State private var newChapterTitle = ""
    @State private var editingChapterID: UUID?
    @State private var editingTitle = ""
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VoomSectionHeader(
                    icon: "bookmark",
                    title: "Chapters",
                    count: chapters.isEmpty ? nil : chapters.count
                )
                Spacer()
                if !transcriptSegments.isEmpty {
                    ToolPillButton(
                        icon: isGenerating ? "hourglass" : "sparkles",
                        label: "Auto-Generate",
                        isActive: false
                    ) {
                        Task { await autoGenerateChapters() }
                    }
                    .disabled(isGenerating)
                }
                ToolPillButton(icon: "plus", label: "Add") {
                    addChapter()
                }
            }
            .padding(.horizontal, VoomTheme.spacingLG)
            .padding(.vertical, VoomTheme.spacingMD)

            if chapters.isEmpty {
                Text("No chapters yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(VoomTheme.textTertiary)
                    .padding(.horizontal, VoomTheme.spacingLG)
                    .padding(.bottom, VoomTheme.spacingLG)
            } else {
                VStack(spacing: 2) {
                    ForEach(sortedChapters) { chapter in
                        chapterRow(chapter)
                    }
                }
                .padding(.horizontal, VoomTheme.spacingSM)
                .padding(.bottom, VoomTheme.spacingMD)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .fill(VoomTheme.backgroundCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusLarge, style: .continuous)
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
    }

    private var sortedChapters: [Chapter] {
        chapters.sorted { $0.timestamp < $1.timestamp }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: Chapter) -> some View {
        let isActive = isChapterActive(chapter)
        HStack(spacing: 10) {
            Text(formatTimestamp(chapter.timestamp))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? Color.white : VoomTheme.textTertiary)
                .frame(width: 38, alignment: .trailing)

            Image(systemName: "bookmark.fill")
                .font(.system(size: 8))
                .foregroundStyle(isActive ? Color.white : VoomTheme.accentOrange)

            if editingChapterID == chapter.id {
                TextField("Title", text: $editingTitle)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .onSubmit { commitChapterEdit(chapter) }
            } else {
                Text(chapter.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? VoomTheme.textPrimary : VoomTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            Button {
                chapters.removeAll { $0.id == chapter.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(VoomTheme.textQuaternary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .fill(isActive ? Color.white.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSeek(chapter.timestamp) }
        .onTapGesture(count: 2) {
            editingChapterID = chapter.id
            editingTitle = chapter.title
        }
    }

    private func isChapterActive(_ chapter: Chapter) -> Bool {
        let nextTimestamp = sortedChapters.first { $0.timestamp > chapter.timestamp }?.timestamp
        if let next = nextTimestamp {
            return currentTime >= chapter.timestamp && currentTime < next
        }
        return currentTime >= chapter.timestamp
    }

    private func addChapter() {
        let chapter = Chapter(timestamp: currentTime, title: "Chapter \(chapters.count + 1)")
        chapters.append(chapter)
    }

    private func autoGenerateChapters() async {
        guard !transcriptSegments.isEmpty else { return }
        isGenerating = true
        let generated = await TextAnalysisService.shared.generateChapters(from: transcriptSegments)
        if !generated.isEmpty {
            chapters = generated
        }
        isGenerating = false
    }

    private func commitChapterEdit(_ chapter: Chapter) {
        if let idx = chapters.firstIndex(where: { $0.id == chapter.id }) {
            chapters[idx].title = editingTitle.isEmpty ? chapter.title : editingTitle
        }
        editingChapterID = nil
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%d:%02d", m, s)
    }
}
