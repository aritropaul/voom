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

        WhatsNew(
            version: "3.1.0",
            title: "What's New in Voom",
            features: [
                WhatsNew.Feature(
                    image: .init(systemName: "brain", foregroundColor: .purple),
                    title: "Bring Your Own AI",
                    subtitle: "Connect your own API key from OpenAI, Anthropic, Google, or xAI for titles, summaries, and chapters."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "key.fill", foregroundColor: .orange),
                    title: "Auto-Detect Provider",
                    subtitle: "Paste an API key and Voom automatically selects the right provider and model."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "arrow.triangle.branch", foregroundColor: .green),
                    title: "Seamless Fallback",
                    subtitle: "No API key? Voom uses Apple's on-device model automatically — nothing to configure."
                ),
            ],
            primaryAction: WhatsNew.PrimaryAction(title: "Continue")
        )

        // Also catches up on 4.0–4.2, which shipped without a What's New entry.
        WhatsNew(
            version: "4.3.0",
            title: "What's New in Voom",
            features: [
                WhatsNew.Feature(
                    image: .init(systemName: "person.2.wave.2.fill", foregroundColor: .blue),
                    title: "Sharper Speaker Labels",
                    subtitle: "Meetings are diarized on your Mac with NVIDIA's Nemotron 3 — up to eight speakers, labeled word by word, and speaker echo is no longer mistaken for you."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "macwindow", foregroundColor: .purple),
                    title: "Record a Window, Pick a Camera",
                    subtitle: "Record a single window as it moves between displays, and choose any camera — including your iPhone."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "play.rectangle.on.rectangle.fill", foregroundColor: .indigo),
                    title: "A New Share Page",
                    subtitle: "Viewers watch, read the transcript, and leave comments pinned to the exact moment, all side by side."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "scissors", foregroundColor: .pink),
                    title: "Editing Tools",
                    subtitle: "Pull AI clips, edit the transcript, blur sensitive areas, and export transcripts."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "externaldrive.fill.badge.checkmark", foregroundColor: .green),
                    title: "Recordings That Survive",
                    subtitle: "Quitting or running out of disk mid-recording keeps what you captured, and recording no longer slows your Mac."
                ),
                WhatsNew.Feature(
                    image: .init(systemName: "icloud.and.arrow.up.fill", foregroundColor: .orange),
                    title: "One-Click Self-Hosting",
                    subtitle: "Deploy your own share server to Cloudflare in one click and manage your links from a private dashboard."
                ),
            ],
            primaryAction: WhatsNew.PrimaryAction(title: "Continue")
        )
    }
}
