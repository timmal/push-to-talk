import Foundation

public struct Metrics: Equatable {
    public let totalWords: Int
    public let wpm7d: Int           // rounded to nearest int
    public init(totalWords: Int, wpm7d: Int) { self.totalWords = totalWords; self.wpm7d = wpm7d }
}

public protocol MetricsComputing {
    func current(now: Date) throws -> Metrics
}

public final class MetricsEngine: MetricsComputing {
    private let store: HistoryStoring
    private let resetAnchor: () -> Int64
    public init(store: HistoryStoring, resetAnchor: @escaping () -> Int64 = { 0 }) {
        self.store = store
        self.resetAnchor = resetAnchor
    }

    public func current(now: Date = Date()) throws -> Metrics {
        let anchor = resetAnchor()
        let totalSums = try store.sumsSince(anchor)
        let sevenDaysAgo = Int64((now.timeIntervalSince1970 - 7 * 86400) * 1000)
        let wpmAnchor = max(anchor, sevenDaysAgo)
        let sums = try store.sumsSince(wpmAnchor)
        let wpm: Int
        if sums.durationMs > 0 {
            wpm = Int((Double(sums.words) * 60_000.0 / Double(sums.durationMs)).rounded())
        } else {
            wpm = 0
        }
        return Metrics(totalWords: totalSums.words, wpm7d: wpm)
    }
}
