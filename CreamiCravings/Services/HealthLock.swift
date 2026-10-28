import Foundation
import LocalAuthentication
import Observation

/// Face ID (or the device passcode) in front of the Health half of the app. Unlocks when Health is entered, and again after
/// five minutes in the background.
@MainActor @Observable
final class HealthLock {
    nonisolated static let relockAfter: TimeInterval = 5 * 60

    private(set) var unlocked = false
    private(set) var failed = false
    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var running = false

    /// True when the app was away long enough that Health must be unlocked again.
    nonisolated static func shouldRelock(leftAt: Date?, now: Date, timeout: TimeInterval = relockAfter) -> Bool {
        guard let leftAt else { return false }
        return now.timeIntervalSince(leftAt) >= timeout
    }

    func lock() { unlocked = false }

    func appLeft(at now: Date = Date()) { leftAt = now }

    func appReturned(at now: Date = Date()) {
        if HealthLock.shouldRelock(leftAt: leftAt, now: now) { unlocked = false }
        leftAt = nil
    }

    /// Prompts for Face ID, falling back to the passcode. Succeeds without a prompt when the device has neither.
    func unlock(reason: String = "Unlock your health data") async {
        guard !unlocked, !running else { return }
        running = true
        defer { running = false }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { unlocked = true; failed = false; return }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            unlocked = ok; failed = !ok
        } catch {
            unlocked = false; failed = true
        }
    }
}
