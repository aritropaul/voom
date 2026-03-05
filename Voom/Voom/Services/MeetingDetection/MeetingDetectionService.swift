import Foundation
import EventKit
import AVFoundation
import CoreMediaIO
import os

private let logger = Logger(subsystem: "com.voom.app", category: "MeetingDetection")

actor MeetingDetectionService {
    static let shared = MeetingDetectionService()

    private let eventStore = EKEventStore()
    private var pollTask: Task<Void, Never>?
    private var promptedEventIDs: Set<String> = []
    private var cachedEvents: [EKEvent] = []
    private var lastCalendarRefresh: Date = .distantPast
    private var wasCameraOn = false
    private var didPostAutoStop = false

    private let cameraCheckInterval: TimeInterval = 10
    private let calendarRefreshInterval: TimeInterval = 60
    private let autoStopSilenceThreshold: TimeInterval = 10

    private init() {}

    // MARK: - Calendar Access

    func requestCalendarAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            if granted {
                logger.notice("[Voom] Calendar access granted")
            } else {
                logger.notice("[Voom] Calendar access denied")
            }
            return granted
        } catch {
            logger.error("[Voom] Calendar access request failed: \(error)")
            return false
        }
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        logger.notice("[Voom] Meeting detection polling started")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForMeeting()
                try? await Task.sleep(for: .seconds(self?.cameraCheckInterval ?? 10))
            }
        }
    }

    /// Called when user dismisses meeting panel — allow next meeting to trigger
    func clearPromptedEvents() {
        promptedEventIDs.removeAll()
        lastCalendarRefresh = .distantPast // force refresh on next poll
        logger.notice("[Voom] Cleared prompted events for next meeting")
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        promptedEventIDs.removeAll()
        cachedEvents.removeAll()
        logger.notice("[Voom] Meeting detection polling stopped")
    }

    // MARK: - Detection

    private func checkForMeeting() async {
        let now = Date()
        let cameraInUse = isCameraInUseByAnotherApp()

        // Detect camera off→on transition: clear prompted IDs
        if cameraInUse && !wasCameraOn {
            promptedEventIDs.removeAll()
            logger.notice("[Voom] Camera turned on, cleared prompted IDs")
        }

        // Detect camera on→off transition: clean up
        if !cameraInUse && wasCameraOn {
            promptedEventIDs.removeAll()
            let appState = await MainActor.run { AppDelegate.shared?.appState }
            if let appState {
                await MainActor.run {
                    appState.detectedMeeting = nil
                    MeetingPanelManager.shared.dismiss()
                }
            }
            wasCameraOn = false
            logger.notice("[Voom] Camera turned off, reset state")
            return
        }
        wasCameraOn = cameraInUse

        // Always refresh calendar when camera is on, otherwise every 60s
        let refreshInterval = cameraInUse ? cameraCheckInterval : calendarRefreshInterval
        if now.timeIntervalSince(lastCalendarRefresh) >= refreshInterval {
            refreshCalendarEvents()
            lastCalendarRefresh = now
        }

        // Find the first active meeting that hasn't been prompted yet
        let unpromotedMeeting = findActiveUnpromptedMeeting()
        let eventCount = self.cachedEvents.count
        let promptedCount = self.promptedEventIDs.count
        logger.notice("[Voom] Poll: camera=\(cameraInUse), meeting=\(unpromotedMeeting?.title ?? "nil"), cached=\(eventCount), prompted=\(promptedCount)")

        let appState = await MainActor.run { AppDelegate.shared?.appState }
        guard let appState else { return }

        let recordingState = await MainActor.run { appState.recordingState }

        if cameraInUse, let meeting = unpromotedMeeting, recordingState == .idle {
            promptedEventIDs.insert(meeting.eventIdentifier)
            didPostAutoStop = false
            let detected = DetectedMeeting(
                eventIdentifier: meeting.eventIdentifier,
                title: meeting.title ?? "Meeting",
                startDate: meeting.startDate,
                endDate: meeting.endDate
            )
            await MainActor.run {
                appState.detectedMeeting = detected
                MeetingPanelManager.shared.show(meeting: detected, appState: appState)
            }
            logger.notice("[Voom] Meeting detected: \(meeting.title ?? "Untitled")")
        }

        // Auto-stop meeting recording when camera off AND system audio silent
        let isMeetingRec = await MainActor.run { appState.isMeetingRecording }
        if !cameraInUse && (recordingState == .recording || recordingState == .paused) && isMeetingRec && !didPostAutoStop {
            let silenceDuration = now.timeIntervalSince(StreamOutput.lastSystemAudioActivity)
            if silenceDuration > autoStopSilenceThreshold {
                didPostAutoStop = true
                logger.notice("[Voom] Auto-stopping meeting recording (camera off, audio silent for \(Int(silenceDuration))s)")
                await MainActor.run {
                    NotificationCenter.default.post(name: .autoStopMeetingRecording, object: nil)
                }
            }
        }
    }

    private func refreshCalendarEvents() {
        let now = Date()
        let startDate = now.addingTimeInterval(-120) // 2 min ago
        let endDate = now.addingTimeInterval(3600)   // 1 hour ahead
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        cachedEvents = eventStore.events(matching: predicate)

        // Prune stale prompted IDs
        let activeIDs = Set(cachedEvents.compactMap(\.eventIdentifier))
        promptedEventIDs.formIntersection(activeIDs)

        // Find next upcoming meeting for menu bar display
        updateUpcomingMeeting(now: now)
    }

    private func updateUpcomingMeeting(now: Date) {
        // Find soonest event that is currently active or upcoming
        let candidate = cachedEvents
            .sorted { $0.startDate < $1.startDate }
            .first { $0.endDate > now }

        // Extract URL on actor before crossing to MainActor
        let upcoming: UpcomingMeeting?
        if let event = candidate {
            let urlInfo = extractMeetingURL(from: event)
            upcoming = UpcomingMeeting(
                title: event.title ?? "Meeting",
                startDate: event.startDate,
                endDate: event.endDate,
                meetingURL: urlInfo?.0,
                serviceName: urlInfo?.1
            )
        } else {
            upcoming = nil
        }

        Task { @MainActor in
            guard let appState = AppDelegate.shared?.appState else { return }
            appState.upcomingMeeting = upcoming
        }
    }

    // MARK: - Meeting URL Extraction

    private func extractMeetingURL(from event: EKEvent) -> (URL, String)? {
        // 1. Check event.url first
        if let url = event.url, let service = serviceName(for: url) {
            return (url, service)
        }

        // 2. Scan event.location
        if let location = event.location, let result = findMeetingURL(in: location) {
            return result
        }

        // 3. Scan event.notes
        if let notes = event.notes, let result = findMeetingURL(in: notes) {
            return result
        }

        return nil
    }

    private func findMeetingURL(in text: String) -> (URL, String)? {
        let pattern = #"https?://[^\s<>\"\')]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let url = URL(string: String(text[matchRange])),
                  let service = serviceName(for: url) else { continue }
            return (url, service)
        }
        return nil
    }

    private func serviceName(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("meet.google.com") { return "Google Meet" }
        if host.contains("zoom.us") { return "Zoom" }
        if host.contains("teams.microsoft.com") { return "Microsoft Teams" }
        if host.contains("webex.com") { return "Webex" }
        // Any other URL with a video-call-like pattern
        if host.contains("facetime.apple.com") { return "FaceTime" }
        // Generic URL — still return a label so Join link shows
        if url.scheme == "https" || url.scheme == "http" { return "video call" }
        return nil
    }

    private func findActiveUnpromptedMeeting() -> EKEvent? {
        let now = Date()
        let buffer: TimeInterval = 120 // 2 min buffer
        return cachedEvents
            .sorted { $0.startDate < $1.startDate }
            .first { event in
                let start = event.startDate.addingTimeInterval(-buffer)
                let end = event.endDate.addingTimeInterval(buffer)
                return now >= start && now <= end && !promptedEventIDs.contains(event.eventIdentifier)
            }
    }

    private func isCameraInUseByAnotherApp() -> Bool {
        // Method 1: AVFoundation (works for native apps like Zoom, FaceTime)
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        for device in discoverySession.devices {
            if device.isInUseByAnotherApplication { return true }
        }

        // Method 2: CoreMediaIO kCMIODevicePropertyDeviceIsRunningSomewhere
        // Detects camera usage globally including browser-based apps (Chrome, Safari)
        if isCameraRunningAnywhere() { return true }

        return false
    }

    private func isCameraRunningAnywhere() -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return false }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: deviceCount)
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propertyAddress, 0, nil, dataSize, &dataSize, &devices
        ) == noErr else { return false }

        for deviceID in devices {
            var isRunningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )

            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(deviceID, &isRunningAddress, 0, nil, size, &size, &isRunning) == noErr {
                logger.notice("[Voom] CMIO device \(deviceID): isRunning=\(isRunning)")
                if isRunning != 0 { return true }
            }
        }
        return false
    }
}
