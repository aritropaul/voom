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
    }
}
