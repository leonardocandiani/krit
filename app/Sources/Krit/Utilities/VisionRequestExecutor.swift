import Foundation

/// Runs synchronous Vision requests away from AppKit's main thread. Vision's
/// `VNImageRequestHandler.perform` blocks until recognition finishes, so callers
/// return only their immutable result to the main actor.
enum VisionRequestExecutor {
    static func perform<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }
}
