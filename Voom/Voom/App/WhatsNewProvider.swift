import SwiftUI
import WhatsNewKit

extension VoomApp: @preconcurrency WhatsNewCollectionProvider {

    var whatsNewCollection: WhatsNewCollection {
        WhatsNew(
            version: "3.0.1",
            title: "What's New in Voom",
            features: [
                WhatsNew.Feature(
                    image: .init(systemName: "bolt.circle.fill", foregroundColor: .orange),
                    title: "Web-Optimized Sharing",
                    subtitle: "Videos are re-encoded to H.264 for universal browser playback — smaller files, faster loading."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "captions.bubble.fill", foregroundColor: .blue),
                    title: "Captions & Speaker Labels",
                    subtitle: "Shared videos now include captions with speaker names, visible in the player and in fullscreen."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "list.bullet.rectangle.fill", foregroundColor: .green),
                    title: "Chapters on Share Pages",
                    subtitle: "Auto-generated chapters appear on share pages with clickable timestamps and seekbar markers."
                ),
            ],
            primaryAction: WhatsNew.PrimaryAction(title: "Continue")
        )

        WhatsNew(
            version: "3.0.2",
            title: "What's New in Voom",
            features: [
                WhatsNew.Feature(
                    image: .init(systemName: "person.2.fill", foregroundColor: .blue),
                    title: "Meeting Recording Pipeline",
                    subtitle: "Meeting recordings now use a dedicated recorder with HD/2K resolution, 30fps, and split-track speaker diarization."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "text.bubble.fill", foregroundColor: .green),
                    title: "Speaker-Aware Summaries",
                    subtitle: "AI-generated titles and summaries now include speaker context from diarized meeting transcripts."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "sparkles", foregroundColor: .orange),
                    title: "Improved AI Generation",
                    subtitle: "Title and summary generation now works reliably for long recordings by subsampling transcripts to fit the on-device model."
                ),
            ],
            primaryAction: WhatsNew.PrimaryAction(title: "Continue")
        )
    }
}
