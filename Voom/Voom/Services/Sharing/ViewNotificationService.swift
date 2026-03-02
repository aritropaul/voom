import Foundation
import UserNotifications

actor ViewNotificationService {
    static let shared = ViewNotificationService()

    private var pollTimer: Task<Void, Never>?
    private let pollInterval: TimeInterval = 300 // 5 minutes

    private init() {}

    func startPolling() {
        stopPolling()
        pollTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 300))
                await self?.checkForNewViews()
            }
        }
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func checkForNewViews() async {
        guard ShareConfig.isConfigured else { return }

        // Get all shared recordings with share codes
        let recordings = await MainActor.run {
            RecordingStore.shared.recordings.filter { $0.shareCode != nil }
        }

        guard !recordings.isEmpty else { return }

        let shareCodes = recordings.compactMap { $0.shareCode }
        guard !shareCodes.isEmpty else { return }

        do {
            let baseURL = ShareConfig.workerBaseURL
            guard let url = URL(string: baseURL + "/api/check-views") else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(ShareConfig.apiSecret)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["shareCodes": shareCodes])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }

            struct ViewsResponse: Decodable {
                let views: [String: Int]
            }

            let viewsResponse = try JSONDecoder().decode(ViewsResponse.self, from: data)

            for recording in recordings {
                guard let code = recording.shareCode,
                      let newCount = viewsResponse.views[code] else { continue }

                let lastNotified = recording.lastNotifiedViewCount ?? 0
                if newCount > lastNotified {
                    await sendNotification(title: recording.title, viewCount: newCount)

                    // Update recording with new count
                    await MainActor.run {
                        if var rec = RecordingStore.shared.recording(for: recording.id) {
                            rec.lastNotifiedViewCount = newCount
                            RecordingStore.shared.update(rec)
                        }
                    }
                }
            }
        } catch {
            NSLog("[Voom] View check failed: %@", "\(error)")
        }
    }

    private func sendNotification(title: String, viewCount: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "New views on your recording"
        content.body = "\"\(title)\" now has \(viewCount) \(viewCount == 1 ? "view" : "views")"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}
