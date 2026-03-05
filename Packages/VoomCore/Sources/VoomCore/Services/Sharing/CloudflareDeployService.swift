import Foundation
import CryptoKit

// MARK: - Deploy Progress

public enum DeployStepStatus: Equatable {
    case pending
    case inProgress
    case completed
    case skipped(String)
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .failed: return true
        default: return false
        }
    }
}

public struct DeployStep: Identifiable, Equatable {
    public let id: String
    public let label: String
    public var status: DeployStepStatus = .pending

    public init(id: String, label: String, status: DeployStepStatus = .pending) {
        self.id = id
        self.label = label
        self.status = status
    }
}

@Observable
@MainActor
public final class DeployProgress {
    public var steps: [DeployStep] = [
        DeployStep(id: "discoverAccount", label: "Discover account"),
        DeployStep(id: "createR2Bucket", label: "Create R2 bucket"),
        DeployStep(id: "createD1Database", label: "Create D1 database"),
        DeployStep(id: "initializeSchema", label: "Initialize schema"),
        DeployStep(id: "runMigrations", label: "Run migrations"),
        DeployStep(id: "deployWorker", label: "Deploy worker"),
        DeployStep(id: "enableSubdomain", label: "Enable subdomain"),
        DeployStep(id: "setCronSchedule", label: "Set cron schedule"),
    ]

    public var workerURL: String?
    public var errorMessage: String?
    public var isDeploying = false
    public var isComplete = false
    public var hasFailed = false

    public init() {}

    public func updateStep(_ id: String, status: DeployStepStatus) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].status = status
        }
    }

    public func reset() {
        for i in steps.indices {
            steps[i].status = .pending
        }
        workerURL = nil
        errorMessage = nil
        isDeploying = false
        isComplete = false
        hasFailed = false
    }
}

// MARK: - Deploy Error

public enum CloudflareDeployError: LocalizedError {
    case missingWorkerBundle
    case apiError(String)
    case unexpectedResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .missingWorkerBundle: return "Worker bundle files not found in app resources."
        case .apiError(let msg): return msg
        case .unexpectedResponse(let code): return "Unexpected HTTP response: \(code)"
        }
    }
}

// MARK: - Deploy Service

public actor CloudflareDeployService {
    public static let shared = CloudflareDeployService()

    private init() {}

    private let bucketName = "voom-videos"
    private let databaseName = "voom-share-db"
    private let scriptName = "voom-share"
    private let baseURL = "https://api.cloudflare.com/client/v4"

    // MARK: - Public

    public func deploy(
        apiToken: String,
        progress: DeployProgress
    ) async throws -> (workerURL: String, apiSecret: String) {
        let apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)

        let apiSecret = generateAPISecret()

        await MainActor.run {
            progress.isDeploying = true
            progress.hasFailed = false
            progress.errorMessage = nil
        }

        do {
            // Step 1: Discover account ID from token
            let accountID = try await runStepReturning("discoverAccount", progress: progress) {
                try await self.discoverAccountID(apiToken: apiToken)
            }

            // Step 2: Create R2 bucket
            try await runStep("createR2Bucket", progress: progress) {
                try await self.createR2Bucket(accountID: accountID, apiToken: apiToken)
            }

            // Step 3: Create D1 database
            let dbID = try await runStepReturning("createD1Database", progress: progress) {
                try await self.createD1Database(accountID: accountID, apiToken: apiToken)
            }

            // Step 4: Initialize schema
            try await runStep("initializeSchema", progress: progress) {
                try await self.initializeSchema(accountID: accountID, apiToken: apiToken, databaseID: dbID)
            }

            // Step 5: Run migrations
            try await runStep("runMigrations", progress: progress) {
                try await self.runMigrations(accountID: accountID, apiToken: apiToken, databaseID: dbID)
            }

            // Step 6: Deploy worker
            try await runStep("deployWorker", progress: progress) {
                try await self.deployWorker(accountID: accountID, apiToken: apiToken, databaseID: dbID, apiSecret: apiSecret)
            }

            // Step 7: Enable subdomain
            try await runStep("enableSubdomain", progress: progress) {
                try await self.enableSubdomain(accountID: accountID, apiToken: apiToken)
            }

            // Step 8: Set cron schedule
            try await runStep("setCronSchedule", progress: progress) {
                try await self.setCronSchedule(accountID: accountID, apiToken: apiToken)
            }

            // Discover the worker URL
            let subdomain = try await getWorkersSubdomain(accountID: accountID, apiToken: apiToken)
            let workerURL = "https://\(scriptName).\(subdomain).workers.dev"

            await MainActor.run {
                progress.workerURL = workerURL
                progress.isDeploying = false
                progress.isComplete = true
            }

            return (workerURL, apiSecret)
        } catch {
            await MainActor.run {
                progress.isDeploying = false
                progress.hasFailed = true
                progress.errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    // MARK: - Step Runner

    private func runStep(_ stepID: String, progress: DeployProgress, action: () async throws -> Void) async throws {
        await MainActor.run { progress.updateStep(stepID, status: .inProgress) }
        do {
            try await action()
            await MainActor.run { progress.updateStep(stepID, status: .completed) }
        } catch let error as CloudflareDeployError where isSkippable(error) {
            await MainActor.run { progress.updateStep(stepID, status: .skipped(error.localizedDescription)) }
        } catch {
            await MainActor.run { progress.updateStep(stepID, status: .failed(error.localizedDescription)) }
            throw error
        }
    }

    private func runStepReturning<T>(_ stepID: String, progress: DeployProgress, action: () async throws -> T) async throws -> T {
        await MainActor.run { progress.updateStep(stepID, status: .inProgress) }
        do {
            let result = try await action()
            await MainActor.run { progress.updateStep(stepID, status: .completed) }
            return result
        } catch {
            await MainActor.run { progress.updateStep(stepID, status: .failed(error.localizedDescription)) }
            throw error
        }
    }

    private func isSkippable(_ error: CloudflareDeployError) -> Bool { false }

    // MARK: - API Helpers

    private func cfRequest(path: String, method: String = "GET", apiToken: String, body: Data? = nil, contentType: String? = "application/json") -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        request.timeoutInterval = 60
        return request
    }

    private struct CFResponse<T: Decodable>: Decodable {
        let success: Bool
        let errors: [CFError]?
        let result: T?
    }

    private struct CFError: Decodable {
        let code: Int?
        let message: String
    }

    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareDeployError.apiError("No HTTP response")
        }

        let cfResp = try JSONDecoder().decode(CFResponse<T>.self, from: data)

        if !cfResp.success {
            let errorMsg = cfResp.errors?.first?.message ?? "Unknown API error"
            throw CloudflareDeployError.apiError(errorMsg)
        }

        guard let result = cfResp.result else {
            throw CloudflareDeployError.apiError("Empty response")
        }

        // Check HTTP status as well
        if !(200...299).contains(http.statusCode) && http.statusCode != 409 {
            throw CloudflareDeployError.unexpectedResponse(http.statusCode)
        }

        return result
    }

    // MARK: - Step 1: Discover Account ID

    private struct AccountResult: Decodable {
        let id: String
        let name: String
    }

    private func discoverAccountID(apiToken: String) async throws -> String {
        let request = cfRequest(path: "/accounts", apiToken: apiToken)
        let accounts: [AccountResult] = try await performRequest(request)
        guard let account = accounts.first else {
            throw CloudflareDeployError.apiError("No accounts found for this API token.")
        }
        return account.id
    }

    // MARK: - Step 2: Create R2 Bucket

    private struct R2BucketResult: Decodable {
        let name: String?
    }

    private func createR2Bucket(accountID: String, apiToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": bucketName])
        let request = cfRequest(path: "/accounts/\(accountID)/r2/buckets", method: "PUT", apiToken: apiToken, body: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareDeployError.apiError("No HTTP response")
        }

        // 409 = bucket already exists, that's fine
        if http.statusCode == 409 { return }

        guard (200...299).contains(http.statusCode) else {
            let errorMsg = parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw CloudflareDeployError.apiError(errorMsg)
        }
    }

    // MARK: - Step 3: Create D1 Database

    private struct D1Database: Decodable {
        let uuid: String
        let name: String
    }

    private struct D1ListResult: Decodable {
        let uuid: String?
        let name: String?
    }

    private func createD1Database(accountID: String, apiToken: String) async throws -> String {
        // List existing databases to check if ours already exists
        let listRequest = cfRequest(path: "/accounts/\(accountID)/d1/database?name=\(databaseName)", apiToken: apiToken)
        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)

        if let http = listResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            if let listResp = try? JSONDecoder().decode(CFResponse<[D1Database]>.self, from: listData),
               listResp.success,
               let existing = listResp.result?.first(where: { $0.name == databaseName }) {
                return existing.uuid
            }
        }

        // Create new database
        let body = try JSONSerialization.data(withJSONObject: ["name": databaseName])
        let createRequest = cfRequest(path: "/accounts/\(accountID)/d1/database", method: "POST", apiToken: apiToken, body: body)
        let db: D1Database = try await performRequest(createRequest)
        return db.uuid
    }

    // MARK: - Step 4: Initialize Schema

    private func initializeSchema(accountID: String, apiToken: String, databaseID: String) async throws {
        guard let schemaURL = Bundle.main.url(forResource: "schema", withExtension: "sql", subdirectory: "WorkerBundle"),
              let schemaSQL = try? String(contentsOf: schemaURL, encoding: .utf8) else {
            throw CloudflareDeployError.missingWorkerBundle
        }

        // Wrap in IF NOT EXISTS by replacing CREATE TABLE with CREATE TABLE IF NOT EXISTS
        let idempotentSQL = schemaSQL
            .replacingOccurrences(of: "CREATE TABLE ", with: "CREATE TABLE IF NOT EXISTS ")
            .replacingOccurrences(of: "CREATE INDEX ", with: "CREATE INDEX IF NOT EXISTS ")

        try await executeD1SQL(accountID: accountID, apiToken: apiToken, databaseID: databaseID, sql: idempotentSQL)
    }

    // MARK: - Step 5: Run Migrations

    private func runMigrations(accountID: String, apiToken: String, databaseID: String) async throws {
        guard let migrationURL = Bundle.main.url(forResource: "migration_0002", withExtension: "sql", subdirectory: "WorkerBundle"),
              let migrationSQL = try? String(contentsOf: migrationURL, encoding: .utf8) else {
            throw CloudflareDeployError.missingWorkerBundle
        }

        // Split into individual statements and execute each one
        // ALTERs will fail if columns already exist — we catch and skip those
        let statements = migrationSQL
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }

        for statement in statements {
            do {
                try await executeD1SQL(accountID: accountID, apiToken: apiToken, databaseID: databaseID, sql: statement)
            } catch {
                // ALTER TABLE ADD COLUMN will fail if column already exists — that's fine
                let msg = error.localizedDescription.lowercased()
                if msg.contains("duplicate column") || msg.contains("already exists") {
                    continue
                }
                throw error
            }
        }
    }

    private struct D1QueryResult: Decodable {
        let success: Bool?
    }

    private func executeD1SQL(accountID: String, apiToken: String, databaseID: String, sql: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["sql": sql])
        let request = cfRequest(
            path: "/accounts/\(accountID)/d1/database/\(databaseID)/query",
            method: "POST",
            apiToken: apiToken,
            body: body
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareDeployError.apiError("No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMsg = parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw CloudflareDeployError.apiError(errorMsg)
        }
    }

    // MARK: - Step 6: Deploy Worker

    private func deployWorker(accountID: String, apiToken: String, databaseID: String, apiSecret: String) async throws {
        guard let workerURL = Bundle.main.url(forResource: "worker", withExtension: "js", subdirectory: "WorkerBundle"),
              let workerSource = try? String(contentsOf: workerURL, encoding: .utf8) else {
            throw CloudflareDeployError.missingWorkerBundle
        }

        // Build metadata with bindings
        let metadata: [String: Any] = [
            "main_module": "worker.js",
            "compatibility_date": "2024-11-01",
            "bindings": [
                [
                    "type": "r2_bucket",
                    "name": "VIDEOS_BUCKET",
                    "bucket_name": bucketName
                ],
                [
                    "type": "d1",
                    "name": "DB",
                    "id": databaseID
                ],
                [
                    "type": "secret_text",
                    "name": "API_SECRET",
                    "text": apiSecret
                ]
            ]
        ]

        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        // Build multipart form-data
        let boundary = "----VoomDeploy\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var bodyData = Data()

        // Part 1: metadata
        bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
        bodyData.append("Content-Disposition: form-data; name=\"metadata\"; filename=\"metadata.json\"\r\n".data(using: .utf8)!)
        bodyData.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        bodyData.append(metadataJSON)
        bodyData.append("\r\n".data(using: .utf8)!)

        // Part 2: worker script
        bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
        bodyData.append("Content-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\n".data(using: .utf8)!)
        bodyData.append("Content-Type: application/javascript+module\r\n\r\n".data(using: .utf8)!)
        bodyData.append(workerSource.data(using: .utf8)!)
        bodyData.append("\r\n".data(using: .utf8)!)

        // End boundary
        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "\(baseURL)/accounts/\(accountID)/workers/scripts/\(scriptName)")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareDeployError.apiError("No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMsg = parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw CloudflareDeployError.apiError("Worker deploy failed: \(errorMsg)")
        }
    }

    // MARK: - Step 7: Enable Subdomain

    private func enableSubdomain(accountID: String, apiToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["enabled": true])
        let request = cfRequest(
            path: "/accounts/\(accountID)/workers/scripts/\(scriptName)/subdomain",
            method: "POST",
            apiToken: apiToken,
            body: body
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareDeployError.apiError("No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMsg = parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw CloudflareDeployError.apiError("Enable subdomain failed: \(errorMsg)")
        }
    }

    // MARK: - Step 8: Set Cron Schedule

    private func setCronSchedule(accountID: String, apiToken: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            ["cron": "0 0 * * *"]
        ])
        let request = cfRequest(
            path: "/accounts/\(accountID)/workers/scripts/\(scriptName)/schedules",
            method: "PUT",
            apiToken: apiToken,
            body: body
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudflareDeployError.apiError("No HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let errorMsg = parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw CloudflareDeployError.apiError("Set cron failed: \(errorMsg)")
        }
    }

    // MARK: - Workers Subdomain Discovery

    private struct SubdomainResult: Decodable {
        let subdomain: String
    }

    private func getWorkersSubdomain(accountID: String, apiToken: String) async throws -> String {
        let request = cfRequest(path: "/accounts/\(accountID)/workers/subdomain", apiToken: apiToken)
        let result: SubdomainResult = try await performRequest(request)
        return result.subdomain
    }

    // MARK: - Helpers

    private func generateAPISecret() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func parseErrorMessage(_ data: Data) -> String? {
        struct ErrBody: Decodable {
            let errors: [CFError]?
        }
        return (try? JSONDecoder().decode(ErrBody.self, from: data))?.errors?.first?.message
    }
}
