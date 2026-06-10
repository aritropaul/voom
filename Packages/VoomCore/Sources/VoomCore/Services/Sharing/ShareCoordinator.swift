import AppKit
import Foundation

/// Single implementation of the share-link user flows. Views call these and
/// translate the outcome into their own toast/alert UI — the service calls,
/// store updates, and pasteboard side effects live in exactly one place.
@MainActor
public enum ShareCoordinator {

    /// Uploads the recording, persists the share fields, and copies the link.
    @discardableResult
    public static func shareAndCopyLink(_ recording: Recording) async throws -> URL {
        let result = try await ShareService.shared.share(recording: recording)
        var updated = recording
        updated.shareURL = result.shareURL
        updated.shareCode = result.shareCode
        updated.shareExpiresAt = result.expiresAt
        RecordingStore.shared.update(updated)
        copy(result.shareURL)
        return result.shareURL
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
