import Foundation

/// Bounds how many consecutive `SSHStderrClassification.transientMuxRefusal`
/// failures a caller may hide from the user before reporting one.
///
/// Absorbing every one of them, unbounded, would make a genuinely wedged
/// ControlMaster — `MaxSessions` never freeing a slot — look exactly like a
/// silent hang instead of a reported failure. Past the bound, the failure
/// surfaces exactly the way an ordinary one always has, and the count starts
/// over, so a later run of refusals still gets the full budget.
struct MuxRefusalAbsorptionPolicy: Equatable {
    private(set) var consecutiveAbsorbed = 0
    let maxConsecutive: Int

    init(maxConsecutive: Int = 3) {
        self.maxConsecutive = maxConsecutive
    }

    /// Called once per failed attempt. Returns whether THIS attempt's failure
    /// should be absorbed (hidden) rather than shown.
    mutating func shouldAbsorb(classification: SSHStderrClassification) -> Bool {
        guard classification == .transientMuxRefusal else {
            consecutiveAbsorbed = 0
            return false
        }
        guard consecutiveAbsorbed < maxConsecutive else {
            consecutiveAbsorbed = 0
            return false
        }
        consecutiveAbsorbed += 1
        return true
    }

    /// Called on a successful attempt, so a later failure starts the count
    /// fresh rather than carrying forward a run of near-misses that never
    /// actually reached the bound.
    mutating func succeeded() {
        consecutiveAbsorbed = 0
    }
}
