import Foundation

public enum UsagePredictionPolicy: Equatable, Sendable {
    /// Show the current diagram, including a pace estimate while history grows.
    case display
    /// Require fresh, consistent evidence before reporting a pattern forecast.
    case verifiedReporting
}

public struct UsagePredictionEvidence: Sendable {
    public enum Status: String, Sendable {
        case available = "ok"
        case unavailable
        case exhausted
        case staleHistory = "stale_history"
        case insufficientHistory = "insufficient_history"
    }
    public internal(set) var status: Status = .unavailable
    public internal(set) var reason: String?
    public internal(set) var latestSampleAt: Date?
    public internal(set) var newestStoredSampleAt: Date?
    public internal(set) var rejectedSampleCount = 0
    public internal(set) var sampleCount = 0
    public internal(set) var historySpanSeconds: TimeInterval?
    public internal(set) var recentRatePercentPointsPerHour: Double?
    public internal(set) var recentRateSpanSeconds: TimeInterval?

    public init(status: Status = .unavailable, reason: String? = nil) {
        self.status = status
        self.reason = reason
    }
}

public struct UsagePrediction: Sendable {
    public let projection: QuotaProjection
    public let evidence: UsagePredictionEvidence
    public let samples: [QuotaSample]

    public init(projection: QuotaProjection, evidence: UsagePredictionEvidence, samples: [QuotaSample]) {
        self.projection = projection
        self.evidence = evidence
        self.samples = samples
    }
}

public enum UsagePredictionEngine {
    public static func evaluate(snapshot: RateLimitSnapshot?, samples: [QuotaSample],
                                now: Date = Date(), policy: UsagePredictionPolicy = .display) -> UsagePrediction {
        var evidence = UsagePredictionEvidence()
        let current = snapshot?.secondary?.usedPercent ?? 0
        let empty = QuotaProjection(currentUsedPercent: current, idealUsedPercent: nil,
            projectedUsedPercentAtReset: nil, resetDate: snapshot?.secondary?.resetDate,
            windowStartDate: nil, paceState: current >= 100 ? .slowDown : .noData)
        let displayed = policy == .display ? QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now) : empty
        let displayedSamples: [QuotaSample]
        if policy == .display, let snapshot, let window = snapshot.secondary,
           let reset = window.resetDate, let minutes = window.windowDurationMins, minutes > 0 {
            displayedSamples = QuotaProjectionEngine.currentWindowSamples(snapshot: snapshot,
                startDate: reset.addingTimeInterval(-Double(minutes) * 60), resetDate: reset, now: now, samples: samples)
        } else { displayedSamples = [] }
        func result(_ projection: QuotaProjection = empty, _ selected: [QuotaSample] = []) -> UsagePrediction {
            UsagePrediction(projection: policy == .display ? displayed : projection, evidence: evidence,
                samples: policy == .display ? displayedSamples : selected)
        }
        guard let snapshot, let window = snapshot.secondary,
              let reset = window.resetDate, reset > now,
              let minutes = window.windowDurationMins, minutes > 0 else {
            evidence.reason = "missing_or_expired_reset"
            return result()
        }
        if current >= 100 {
            evidence.status = .exhausted
            return result()
        }
        evidence.newestStoredSampleAt = samples.map(\.capturedAt).max()
        let start = reset.addingTimeInterval(-Double(minutes) * 60)
        let candidates = samples.filter {
            $0.limitId == (snapshot.limitId ?? "codex") && $0.windowMinutes == minutes &&
            UsageHistoryContract.matchesReset($0.resetsAt, live: reset) &&
            (snapshot.planType == nil || $0.planType == snapshot.planType) &&
            $0.capturedAt >= start && $0.capturedAt <= now
        }.sorted {
            $0.capturedAt == $1.capturedAt ? $0.usedPercent < $1.usedPercent : $0.capturedAt < $1.capturedAt
        }
        evidence.rejectedSampleCount = samples.count - candidates.count
        var selected: [QuotaSample] = []
        for sample in candidates {
            if selected.last?.capturedAt == sample.capturedAt { selected.removeLast() }
            selected.append(sample)
        }
        evidence.sampleCount = selected.count
        guard let first = selected.first, let latest = selected.last else {
            evidence.reason = "no_matching_history"
            return result()
        }
        evidence.latestSampleAt = latest.capturedAt
        evidence.historySpanSeconds = latest.capturedAt.timeIntervalSince(first.capturedAt)
        guard selected.allSatisfy({ $0.usedPercent.isFinite && $0.usedPercent >= 0 }),
              latest.usedPercent <= current,
              zip(selected, selected.dropFirst()).allSatisfy({ $0.usedPercent <= $1.usedPercent }) else {
            evidence.reason = "history_usage_mismatch"
            return result(empty, selected)
        }
        guard now.timeIntervalSince(latest.capturedAt) <= 1800 else {
            evidence.status = .staleHistory
            evidence.reason = samples.contains { $0.capturedAt > latest.capturedAt && $0.capturedAt <= now
                && now.timeIntervalSince($0.capturedAt) <= 1800 }
                ? "fresh_samples_do_not_match" : "no_recent_samples"
            return result(empty, selected)
        }
        guard selected.count >= 3, latest.capturedAt.timeIntervalSince(first.capturedAt) >= 3600 else {
            evidence.status = .insufficientHistory
            return result(empty, selected)
        }
        let rateStart = selected.last(where: { $0.capturedAt <= now.addingTimeInterval(-3600) }) ?? first
        let span = now.timeIntervalSince(rateStart.capturedAt)
        evidence.recentRateSpanSeconds = span
        evidence.recentRatePercentPointsPerHour = (current - rateStart.usedPercent) * 3600 / span
        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: selected, now: now)
        guard projection.cycleRunForecast != nil else {
            evidence.status = .insufficientHistory
            evidence.reason = "no_observed_usage_increase"
            return result(empty, selected)
        }
        evidence.status = .available
        return result(projection, selected)
    }

    public static func crossingDate(in segments: [QuotaForecastLineSegment], limit: Double = 100) -> Date? {
        for segment in segments {
            if segment.startUsedPercent >= limit { return segment.startDate }
            if segment.endUsedPercent >= limit, segment.endUsedPercent > segment.startUsedPercent {
                let fraction = (limit - segment.startUsedPercent) / (segment.endUsedPercent - segment.startUsedPercent)
                return segment.startDate.addingTimeInterval(fraction * segment.endDate.timeIntervalSince(segment.startDate))
            }
        }
        return nil
    }
}
