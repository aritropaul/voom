import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.voom.app", category: "Share")

/// Single implementation of the share-link user flows. Views call these and
/// translate the outcome into their own toast/alert UI — the service calls,
/// store updates, and pasteboard side effects live in exactly one place.
@MainActor
public enum ShareCoordinator {

    /// Uploads the recording, persists the share fields, and copies the link.
    @discardableResult
    public static func shareAndCopyLink(_ recording: Recording) async throws -> URL {
        let result = try await ShareService.shared.share(recording: recording)
        // Re-read rather than writing back the pre-upload snapshot: transcription
        // may have finished during the upload, and the snapshot would discard it.
        var updated = RecordingStore.shared.recording(for: recording.id) ?? recording
        updated.shareURL = result.shareURL
        updated.shareCode = result.shareCode
        updated.shareExpiresAt = result.expiresAt
        RecordingStore.shared.update(updated)
        copy(result.shareURL)

        // The upload posted the pre-upload transcript; push whatever landed since.
        if updated.transcriptSegments != recording.transcriptSegments
            || updated.title != recording.title
            || updated.summary != recording.summary
            || updated.chapters != recording.chapters {
            do {
                try await syncShareMetadata(recordingID: recording.id)
            } catch {
                logger.error("[Voom] Shared \(result.shareCode) but couldn't update its transcript: \(error.localizedDescription)")
            }
        }
        return result.shareURL
    }

    /// Pushes the recording's current transcript, title, summary and chapters to
    /// its share page, replacing what's there. Call after transcription: a
    /// recording shared before it finished otherwise shows no transcript on the
    /// web. No-op for recordings that aren't shared or whose share has expired.
    public static func syncShareMetadata(recordingID: UUID) async throws {
        guard ShareConfig.isConfigured,
              let recording = RecordingStore.shared.recording(for: recordingID),
              let code = recording.shareCode,
              recording.shareExpiresAt.map({ $0 > Date() }) ?? true else { return }
        try await ShareService.shared.updateMetadata(shareCode: code, recording: recording)
        logger.notice("[Voom] Updated share page \(code) with \(recording.transcriptSegments.count) transcript segments")
    }

    /// Copies an existing share link. Returns false if the recording has none.
    @discardableResult
    public static func copyLink(_ recording: Recording) -> Bool {
        guard let url = recording.shareURL else { return false }
        copy(url)
        return true
    }

    /// Extends the share expiry and persists the new date.
    @discardableResult
    public static func renew(_ recording: Recording) async throws -> Date {
        guard let code = recording.shareCode else { throw ShareError.invalidResponse }
        let newExpiry = try await ShareService.shared.renew(shareCode: code)
        var updated = recording
        updated.shareExpiresAt = newExpiry
        RecordingStore.shared.update(updated)
        return newExpiry
    }

    /// Deletes the share server-side and clears the share fields locally.
    public static func removeShare(_ recording: Recording) async throws {
        guard let code = recording.shareCode else { return }
        try await ShareService.shared.deleteShare(shareCode: code)
        var updated = recording
        updated.shareURL = nil
        updated.shareCode = nil
        updated.shareExpiresAt = nil
        RecordingStore.shared.update(updated)
    }

    private static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
