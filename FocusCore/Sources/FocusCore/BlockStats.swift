import Foundation

/// Time on and off task during a block, and how many times you drifted.
public struct BlockStats: Sendable, Equatable {
    public var onSeconds: TimeInterval = 0
    public var offSeconds: TimeInterval = 0
    /// Each time the display turned red counts once, however long it lasted.
    public var drifts = 0

    public init() {}

    public mutating func add(_ seconds: TimeInterval, onTask: Bool?) {
        switch onTask {
        case true?: onSeconds += seconds
        case false?: offSeconds += seconds
        case nil: break
        }
    }

    /// "On task: 20 min. Off task: 2 min. 3 drifts."
    public var summary: String {
        let on = Int((onSeconds / 60).rounded())
        let off = Int((offSeconds / 60).rounded())
        return "On task: \(on) min. Off task: \(off) min. \(drifts) drift\(drifts == 1 ? "" : "s")."
    }
}
