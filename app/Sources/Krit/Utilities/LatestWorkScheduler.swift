import Foundation

/// State machine for a synchronous background job where only the most recent
/// request is still worth running after the active job completes.
@MainActor
struct LatestWorkScheduler<Value: Equatable> {
    enum Submission: Equatable {
        case start
        case queued
        case alreadyActive
    }

    private(set) var active: Value?
    private(set) var pending: Value?

    mutating func submit(_ value: Value) -> Submission {
        guard let active else {
            self.active = value
            return .start
        }
        if active == value {
            // A return to the in-flight state makes the queued intermediate state
            // obsolete. Let the active work finish instead of recomputing it again.
            pending = nil
            return .alreadyActive
        }
        pending = value
        return .queued
    }

    mutating func complete(_ value: Value) -> Value? {
        guard active == value else { return nil }
        if let pending {
            active = pending
            self.pending = nil
            return pending
        }
        active = nil
        return nil
    }
}
