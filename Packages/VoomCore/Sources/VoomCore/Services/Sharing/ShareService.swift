import Foundation
import AVFoundation
import CryptoKit

// MARK: - Configuration

public enum ShareConfig {
    public static var workerBaseURL: String {
        get { UserDefaults.standard.string(forKey: "ShareWorkerBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ShareWorkerBaseURL") }
    }

    public static var apiSecret: String {
        get { UserDefaults.standard.string(forKey: "ShareAPISecret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ShareAPISecret") }
    }

    public static var isConfigured: Bool {
        !workerBaseURL.isEmpty && !apiSecret.isEmpty
    }
}

// MARK: - Upload Progress Tracker

@Observable
@MainActor
public final class ShareUploadTracker {
    public static let shared = ShareUploadTracker()

    public private(set) var activeUploads: [UUID: Double] = [:]
    public private(set) var uploadErrors: [UUID: String] = [:]

    private init() {}

    public func startUpload(for id: UUID) {
        activeUploads[id] = 0.0
        uploadErrors.removeValue(forKey: id)
    }

    public func updateProgress(for id: UUID, progress: Double) {
        activeUploads[id] = progress
    }

    public func completeUpload(for id: UUID) {
        activeUploads.removeValue(forKey: id)
        uploadErrors.removeValue(forKey: id)
    }

    public func failUpload(for id: UUID, error: String) {
        activeUploads.removeValue(forKey: id)
        uploadErrors[id] = error
    }

    public func isUploading(_ id: UUID) -> Bool {
        activeUploads[id] != nil
    }

    public func progress(for id: UUID) -> Double? {
        activeUploads[id]
    }

    public func clearError(for id: UUID) {
        uploadErrors.removeValue(forKey: id)
    }
}

// MARK: - Share Service

public enum ShareError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(String)
    case uploadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Share service is not configured. Set the Worker URL and API secret in settings."
        case .invalidResponse: return "Received an invalid response from the server."
        case .serverError(let msg): return "Server error: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        }
    }
}

public actor ShareService {
    public static let shared = ShareService()

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

    private nonisolated(unsafe) static let dateFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let dateFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseDate(_ string: String) -> Date {
        if let d = Self.dateFormatterFractional.date(from: string) { return d }
        return Self.dateFormatterBasic.date(from: string) ?? Date()
    }

    // MARK: - Public API

    public func share(recording: Recording) async throws -> (shareURL: URL, shareCode: String, expiresAt: Date) {
        guard ShareConfig.isConfigured else { throw ShareError.notConfigured }

        let tracker = await ShareUploadTracker.shared
        let pipelineProgress = await SharePipelineProgress.shared

        // Step 0: Optimize video for web
        var uploadFileURL = recording.fileURL
        var optimizedURL: URL?
        var optimizedFileSize: Int64?

        // Upload raw file directly (HEVC supported by modern browsers, avoids re-encoding bottleneck)
        await pipelineProgress.complete(for: recording.id)

        await tracker.startUpload(for: recording.id)

        do {
            // Step 1: Request upload slot (use optimized file size if available)
            let uploadResponse = try await requestUpload(recording: recording, fileSize: optimizedFileSize)

            // Step 2: Upload video file
            try await uploadVideo(
                fileURL: uploadFileURL,
                uploadURL: uploadResponse.uploadURL,
                recordingID: recording.id
            )

            // Step 3: Upload thumbnail for OG image
            if let thumbURL = recording.thumbnailURL {
                try? await uploadThumbnail(
                    thumbURL: thumbURL,
                    shareCode: uploadResponse.shareCode
                )
            }

            // Step 4: Post metadata, transcript, title, summary, chapters, and meeting info
            try await postMetadata(
                shareCode: uploadResponse.shareCode,
                title: recording.title,
                summary: recording.summary,
                segments: recording.transcriptSegments,
                chapters: recording.chapters,
                isMeeting: recording.isMeeting
            )

            await tracker.completeUpload(for: recording.id)

            // Cleanup temp file
            if let tempURL = optimizedURL {
                try? FileManager.default.removeItem(at: tempURL)
            }

            guard let shareURL = URL(string: uploadResponse.shareURL) else {
                throw ShareError.invalidResponse
            }

            let expiresAt = parseDate(uploadResponse.expiresAt)
            return (shareURL, uploadResponse.shareCode, expiresAt)
        } catch {
            // Cleanup temp file on error
            if let tempURL = optimizedURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            await tracker.failUpload(for: recording.id, error: error.localizedDescription)
            throw error
        }
    }

    public func renew(shareCode: String) async throws -> Date {
        guard ShareConfig.isConfigured else { throw ShareError.notConfigured }

        var request = URLRequest(url: apiURL("/api/renew/\(shareCode)"))
        request.httpMethod = "POST"
        applyAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        let renewResponse = try JSONDecoder().decode(RenewResponse.self, from: data)
        return parseDate(renewResponse.expiresAt)
    }

    public func deleteShare(shareCode: String) async throws {
        guard ShareConfig.isConfigured else { throw ShareError.notConfigured }

        var request = URLRequest(url: apiURL("/api/delete/\(shareCode)"))
        request.httpMethod = "DELETE"
        applyAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        // Treat 404 as success — video is already gone
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return
        }
        try validateResponse(response, data: data)
    }

    // MARK: - Private Helpers

    private func requestUpload(recording: Recording, fileSize: Int64? = nil) async throws -> UploadResponse {
        var request = URLRequest(url: apiURL("/api/upload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        var body: [String: Any] = [
            "title": recording.title,
            "duration": recording.duration,
            "width": recording.width,
            "height": recording.height,
            "hasWebcam": recording.hasWebcam,
            "fileSize": fileSize ?? recording.fileSize,
        ]

        // Password protection: SHA-256 hash before sending
        if let password = recording.sharePassword, !password.isEmpty {
            let hash = sha256Hash(password)
            body["password_hash"] = hash
        }

        // CTA fields
        if let ctaURL = recording.ctaURL {
            body["cta_url"] = ctaURL.absoluteString
        }
        if let ctaText = recording.ctaText, !ctaText.isEmpty {
            body["cta_text"] = ctaText
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)

        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    private func sha256Hash(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static let chunkSize = 10 * 1024 * 1024 // 10 MB

    private struct MultipartStartResponse: Decodable {
        let uploadId: String
    }

    private struct MultipartPartResponse: Decodable {
        let partNumber: Int
        let etag: String
    }

    private func uploadVideo(fileURL: URL, uploadURL: String, recordingID: UUID) async throws {
        // Extract shareCode from uploadURL (format: .../api/upload-data/{shareCode})
        guard let shareCode = uploadURL.split(separator: "/").last.map(String.init) else {
            throw ShareError.invalidResponse
        }

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        let totalSize = Int(try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.size] as? Int64 ?? 0)

        // Start multipart upload
        var startReq = URLRequest(url: apiURL("/api/upload-multipart/\(shareCode)"))
        startReq.httpMethod = "POST"
        applyAuth(&startReq)

        let (startData, startResp) = try await URLSession.shared.data(for: startReq)
        try validateResponse(startResp, data: startData)
        let startResult = try JSONDecoder().decode(MultipartStartResponse.self, from: startData)
        let uploadId = startResult.uploadId

        do {
            // Upload parts
            var parts: [[String: Any]] = []
            var offset = 0
            var partNumber = 1

            while offset < totalSize {
                let end = min(offset + Self.chunkSize, totalSize)
                let chunkSize = end - offset

                try fileHandle.seek(toOffset: UInt64(offset))
                let chunk = fileHandle.readData(ofLength: chunkSize)

                var partReq = URLRequest(url: apiURL("/api/upload-part/\(shareCode)/\(uploadId)/\(partNumber)"))
                partReq.httpMethod = "PUT"
                partReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                partReq.timeoutInterval = 300
                applyAuth(&partReq)

                let (partData, partResp) = try await URLSession.shared.upload(for: partReq, from: chunk)
                try validateResponse(partResp, data: partData)
                let partResult = try JSONDecoder().decode(MultipartPartResponse.self, from: partData)

                parts.append(["partNumber": partResult.partNumber, "etag": partResult.etag])

                offset = end

                // Update progress
                let progress = Double(offset) / Double(totalSize)
                let id = recordingID
                await MainActor.run {
                    ShareUploadTracker.shared.updateProgress(for: id, progress: progress)
                }

                partNumber += 1
            }

            // Complete multipart upload
            var completeReq = URLRequest(url: apiURL("/api/upload-complete/\(shareCode)/\(uploadId)"))
            completeReq.httpMethod = "POST"
            completeReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(&completeReq)
            completeReq.httpBody = try JSONSerialization.data(withJSONObject: ["parts": parts])

            let (completeData, completeResp) = try await URLSession.shared.data(for: completeReq)
            try validateResponse(completeResp, data: completeData)
        } catch {
            // Abort the multipart upload so it doesn't stay as "Ongoing" in R2
            try? await abortMultipartUpload(shareCode: shareCode, uploadId: uploadId)
            throw error
        }
    }

    private func abortMultipartUpload(shareCode: String, uploadId: String) async throws {
        var request = URLRequest(url: apiURL("/api/upload-abort/\(shareCode)/\(uploadId)"))
        request.httpMethod = "POST"
        applyAuth(&request)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func uploadThumbnail(thumbURL: URL, shareCode: String) async throws {
        var request = URLRequest(url: apiURL("/api/upload-thumbnail/\(shareCode)"))
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        let thumbData = try Data(contentsOf: thumbURL)
        let (data, response) = try await URLSession.shared.upload(for: request, from: thumbData)
        try validateResponse(response, data: data)
    }

    private func postMetadata(shareCode: String, title: String, summary: String?, segments: [TranscriptEntry], chapters: [Chapter]?, isMeeting: Bool?) async throws {
        var request = URLRequest(url: apiURL("/api/metadata/\(shareCode)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        let segmentDicts = segments.map { seg -> [String: Any] in
            var dict: [String: Any] = ["startTime": seg.startTime, "endTime": seg.endTime, "text": seg.text]
            if let speaker = seg.speaker {
                dict["speaker"] = speaker
            }
            return dict
        }
        var body: [String: Any] = [
            "segments": segmentDicts,
            "title": title,
        ]
        if let summary, !summary.isEmpty {
            body["summary"] = summary
        }
        if let chapters, !chapters.isEmpty {
            body["chapters"] = chapters.map { ch -> [String: Any] in
                ["timestamp": ch.timestamp, "title": ch.title]
            }
        }
        if let isMeeting {
            body["isMeeting"] = isMeeting
        }
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
