import Foundation

/// Token totals per quarter hour, for events too old to keep whole.
///
/// Past five weeks an event is only ever a contribution to one day of the
/// history grid — no window or split reaches that far back — so its model,
/// project and id are dead weight. A quarter hour rather than a day because a
/// local day is not a fixed span of UTC, and every time zone in use is a whole
/// number of quarter hours from it: a bucket never straddles midnight anywhere.
struct UsageRollup: Equatable, Sendable, Codable {
    static let bucketSeconds: TimeInterval = 900

    /// Keyed by quarter hours since 1970.
    private(set) var buckets: [Int: TokenCounts] = [:]

    static func bucket(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / bucketSeconds).rounded(.down))
    }

    mutating func add(_ event: UsageEvent) {
        buckets[Self.bucket(of: event.timestamp), default: .zero] += event.counts
    }

    /// Forgets the buckets these events fall in, ahead of a full re-read that
    /// will fill them again — added on top, every rolled-up token would count
    /// twice.
    mutating func clear(for events: some Sequence<UsageEvent>) {
        for event in events { buckets[Self.bucket(of: event.timestamp)] = nil }
    }

    mutating func prune(before cutoff: Date) {
        let first = Self.bucket(of: cutoff)
        buckets = buckets.filter { $0.key >= first }
    }

    /// Each bucket's start and what was spent in it.
    var totals: some Sequence<(start: Date, counts: TokenCounts)> {
        buckets.lazy.map {
            (Date(timeIntervalSince1970: Double($0.key) * Self.bucketSeconds), $0.value)
        }
    }
}
