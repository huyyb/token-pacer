import Foundation

/// Decides when a threshold crossing is worth interrupting someone over.
///
/// Each mark fires once, and stays quiet until the figure falls back under it.
/// The window used to be told apart by its reset time, but the panel's reset
/// stamp is not always readable and the stand-in moved on every read — so every
/// five-minute read looked like a new window and raised the same card again.
/// The figure itself is the steadier signal: within a window it only climbs,
/// and a reset is the one thing that brings it back down.
struct AlertPolicy: Sendable {
    /// Marks already raised and not yet fallen back under.
    private var fired: Set<Double> = []

    /// The highest threshold newly crossed, or nil for silence.
    mutating func crossing(percent: Double?, thresholds: [Double]) -> Double? {
        guard let percent else { return nil }
        fired = fired.filter { percent >= $0 }
        // A first reading already past the mark counts — the app may have
        // launched mid-window. Every mark passed is spent at once, and the
        // highest is the one said: crossing 90 in one jump is "wrap up", not "warm".
        let crossed = thresholds.filter { percent >= $0 && !fired.contains($0) }
        fired.formUnion(crossed)
        return crossed.max()
    }
}

/// A provider that has just crossed one of the two marks and has not been looked
/// at yet.
///
/// The app used to hand this to macOS as a banner, which meant asking for
/// notification permission for a number the notch was already showing — and on a
/// Mac where that permission had been declined, the whole feature was silent with
/// nothing to say so. The pill raises it itself now: it is the one surface that
/// is always there, and it needs nobody's permission to change shape.
struct ZoneAlert: Equatable, Sendable {
    let source: SourceID
    /// The mark that was crossed, in the user's own numbers.
    let threshold: Double
    let percent: Double
    let resetsAt: Date?
    /// Over rather than watch — the difference between "keep an eye on this" and
    /// "finish what you are doing".
    let isOver: Bool
}
