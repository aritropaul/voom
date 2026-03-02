import Foundation
import AVFoundation

// MARK: - Configuration

enum ShareConfig {
    static var workerBaseURL: String {
        get { UserDefaults.standard.string(forKey: "ShareWorkerBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ShareWorkerBaseURL") }
    }

    static var apiSecret: String {
        get { UserDefaults.standard.string(forKey: "ShareAPISecret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ShareAPISecret") }
    }

    static var isConfigured: Bool {
        !workerBaseURL.isEmpty && !apiSecret.isEmpty
    }
}

// MARK: - Upload Progress Tracker

@Observable
@MainActor
final class ShareUploadTracker {
    static let shared = ShareUploadTracker()

    private(set) var activeUploads: [UUID: Double] = [:]
    private(set) var uploadErrors: [UUID: String] = [:]

    private init() {}

    func startUpload(for id: UUID) {
        activeUploads[id] = 0.0
        uploadErrors.removeValue(forKey: id)
    }

    func updateProgress(for id: UUID, progress: Double) {
        activeUploads[id] = progress
    }

    func completeUpload(for id: UUID) {
        activeUploads.removeValue(forKey: id)
        uploadErrors.removeValue(forKey: id)
    }

    func failUpload(for id: UUID, error: String) {
        activeUploads.removeValue(forKey: id)
        uploadErrors[id] = error
    }

    func isUploading(_ id: UUID) -> Bool {
        activeUploads[id] != nil
    }

    func progress(for id: UUID) -> Double? {
        activeUploads[id]
    }

    func clearError(for id: UUID) {
        uploadErrors.removeValue(forKey: id)
    }
}

// MARK: - Upload Progress Delegate

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let recordingID: UUID

    init(recordingID: UUID) {
        self.recordingID = recordingID
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let id = recordingID
        Task { @MainActor in
            ShareUploadTracker.shared.updateProgress(for: id, progress: progress)
        }
    }
}

// MARK: - Share Service

enum ShareError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Share service is not configured. Set the Worker URL and API secret in settings."
        case .invalidResponse: return "Received an invalid response from the server."
        case .serverError(let msg): return "Server error: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        }
    }
}

actor ShareService {
    static let shared = ShareService()

    private init() {}

    private struct UploadResponse: Decodable {
        let shareCode: String
        let uploadURL: String
        let shareURL: String
        let expiresAt: String
    }

    private struct RenewResponse: Decodable {
        let expiresAt: String
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private var dateFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private func parseDate(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string) ?? Date()
    }

    // MARK: - Public API

    func share(recording: Recording) async throws -> (shareURL: URL, shareCode: String, expiresAt: Date) {
        guard ShareConfig.isConfigured else { throw ShareError.notConfigured }

        let tracker = await ShareUploadTracker.shared
        await tracker.startUpload(for: recording.id)

        do {
            // Step 1: Request upload slot
            let uploadResponse = try await requestUpload(recording: recording)

            // Step 2: Upload video file
            try await uploadVideo(
                fileURL: recording.fileURL,
                uploadURL: uploadResponse.uploadURL,
                recordingID: recording.id
            )

            // Step 3: Post metadata and transcript
            try await postMetadata(
                shareCode: uploadResponse.shareCode,
                segments: recording.transcriptSegments
            )

            await tracker.completeUpload(for: recording.id)

            guard let shareURL = URL(string: uploadResponse.shareURL) else {
                throw ShareError.invalidResponse
            }

            let expiresAt = parseDate(uploadResponse.expiresAt)
            return (shareURL, uploadResponse.shareCode, expiresAt)
        } catch {
            await tracker.failUpload(for: recording.id, error: error.localizedDescription)
            throw error
        }
    }

    func renew(shareCode: String) async throws -> Date {
        guard ShareConfig.isConfigured else { throw ShareError.notConfigured }

        var request = URLRequest(url: apiURL("/api/renew/\(shareCode)"))
        request.httpMethod = "POST"
        applyAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        let renewResponse = try JSONDecoder().decode(RenewResponse.self, from: data)
        return parseDate(renewResponse.expiresAt)
    }

    func deleteShare(shareCode: String) async throws {
        guard ShareConfig.isConfigured else { throw ShareError.notConfigured }

        var request = URLRequest(url: apiURL("/api/delete/\(shareCode)"))
        request.httpMethod = "DELETE"
        applyAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    // MARK: - Private Helpers

    private func requestUpload(recording: Recording) async throws -> UploadResponse {
        var request = URLRequest(url: apiURL("/api/upload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        let body: [String: Any] = [
            "title": recording.title,
            "duration": recording.duration,
            "width": recording.width,
            "height": recording.height,
            "hasWebcam": recording.hasWebcam,
            "fileSize": recording.fileSize,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    private func uploadVideo(fileURL: URL, uploadURL: String, recordingID: UUID) async throws {
        guard let url = URL(string: uploadURL) else { throw ShareError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        let delegate = UploadProgressDelegate(recordingID: recordingID)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let (_, response) = try await session.upload(for: request, fromFile: fileURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ShareError.uploadFailed("Server returned status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        session.invalidateAndCancel()
    }

    private func postMetadata(shareCode: String, segments: [TranscriptEntry]) async throws {
        var request = URLRequest(url: apiURL("/api/metadata/\(shareCode)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        let segmentDicts = segments.map { seg -> [String: Any] in
            ["startTime": seg.startTime, "endTime": seg.endTime, "text": seg.text]
        }
        let body: [String: Any] = ["segments": segmentDicts]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    private func apiURL(_ path: String) -> URL {
        URL(string: ShareConfig.workerBaseURL + path)!
    }

    private func applyAuth(_ request: inout URLRequest) {
        request.setValue("Bearer \(ShareConfig.apiSecret)", forHTTPHeaderField: "Authorization")
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ShareError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errResp = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ShareError.serverError(errResp.error)
            }
            throw ShareError.serverError("HTTP \(httpResponse.statusCode)")
        }
    }
}
