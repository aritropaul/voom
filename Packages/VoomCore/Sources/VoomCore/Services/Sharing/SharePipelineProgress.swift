import Foundation

@Observable
@MainActor
public final class SharePipelineProgress {
    public static let shared = SharePipelineProgress()

    public private(set) var activeOptimizations: [UUID: Double] = [:]

    private init() {}

    public func start(for id: UUID) {
        activeOptimizations[id] = 0.0
    }

    public func update(for id: UUID, progress: Double) {
        activeOptimizations[id] = progress
    }

    public func complete(for id: UUID) {
        activeOptimizations.removeValue(forKey: id)
    }

    public func isOptimizing(_ id: UUID) -> Bool {
        activeOptimizations[id] != nil
    }

    public func progress(for id: UUID) -> Double? {
        activeOptimizations[id]
    }
}
