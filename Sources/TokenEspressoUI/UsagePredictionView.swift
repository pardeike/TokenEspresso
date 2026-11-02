import SwiftUI
import TokenEspresso

public struct UsagePredictionView: View {
    public enum Style: Equatable, Sendable { case micro, preview, detail }
    let title: String
    let provider: String
    let snapshot: RateLimitSnapshot
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let now: Date
    let kind: Style
    let status: String?
    let emphasized: Bool
    let expanded: Bool
    public var accent: Color = .accentColor
    var syncMessage: String? = nil
    public init(title: String, provider: String = "", snapshot: RateLimitSnapshot, samples: [QuotaSample],
                prediction: UsagePrediction? = nil, now: Date = Date(), style: Style = .detail,
                status: String? = nil, emphasized: Bool = false, expanded: Bool = false,
                accent: Color = .accentColor, syncMessage: String? = nil) {
        self.title = title
        self.provider = provider
        self.snapshot = snapshot
        self.samples = samples
        let prediction = prediction ?? UsagePredictionEngine.evaluate(snapshot: snapshot, samples: samples, now: now)
        self.projection = prediction.projection
        self.now = now
        self.kind = style
        self.status = status ?? (prediction.evidence.status == .staleHistory ? "Stale history" : nil)
        self.emphasized = emphasized
        self.expanded = expanded
        self.accent = accent
        self.syncMessage = syncMessage
    }

    private var used: Double { snapshot.secondary?.usedPercent ?? 0 }
    private var fiveHour: Double { status?.hasPrefix("5h limit") == true ? 100 : snapshot.primary?.usedPercent ?? 0 }
    public var usageColor: Color { used >= 100 || projection.paceState == .slowDown ? .red : (status != nil ? .orange : .cyan) }

    public var body: some View {
        GeometryReader { geometry in
            let micro = kind == .micro && !expanded
            let shallow = geometry.size.height < 120
            VStack(alignment: .leading, spacing: micro ? 2 : 4) {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                    Spacer(minLength: 0)
                    if micro { Text("\(Int(used))%").font(.system(size: 12, weight: .semibold)).monospacedDigit() }
                }
                if !micro {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(used))%")
                            .font(.system(size: shallow ? 20 : 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(usageColor).monospacedDigit()
                        if kind == .detail, geometry.size.width > 240, !shallow, let estimate {
                            Text(estimate).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if shallow { Text(status ?? sessionText).font(.system(size: 11)).foregroundStyle(status == nil ? Color.secondary : Color.orange).lineLimit(1) }
                    }
                }
                Group {
                    if kind == .detail && !shallow && geometry.size.width >= 220 {
                        UsageHistoryChart(samples: samples, projection: projection,
                                       snapshot: snapshot, now: now, historyColor: accent)
                    } else {
                        UsageSparkline(samples: samples, projection: projection, showForecast: !micro, historyColor: accent)
                    }
                }
                .overlay {
                    if let balance = remainingBalance {
                        RemainingBalanceOverlay(amount: balance.amount, caption: balance.caption)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                if !micro && !shallow {
                    HStack(spacing: 4) {
                        Text(status ?? sessionText)
                            .foregroundStyle(status == nil ? Color.secondary : Color.orange)
                        Spacer(minLength: 0)
                        if let date = projection.resetDate {
                            Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 11)).lineLimit(1)
                } else if micro, let status {
                    Text(status).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .padding(micro ? 3 : 6)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.primary.opacity(emphasized && !expanded ? 0.045 : 0.015), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
            .clipped()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(remainingBalance.map { "\(Int(used)) percent used, \($0.amount) \($0.caption)" }
            ?? "\(Int(used)) percent used")
        .help("\(provider) · \(title), \(Int(used))% allowance used. \(sessionText). \(status ?? ""). \(syncMessage ?? "")")
    }

    public var sessionText: String {
        if snapshot.limitId == "session", snapshot.secondary?.windowDurationMins == 300 {
            return used >= 100 ? "Limit reached" : "5-hour window"
        }
        guard let session = snapshot.primary else { return "--" }
        let hours = (session.windowDurationMins ?? 300) / 60
        return "\(hours)h \(Int(fiveHour))%"
    }

    public var remainingBalance: (amount: String, caption: String)? {
        guard used >= 100 else { return nil }
        if let credits = snapshot.credits {
            if credits.unlimited { return ("Unlimited", "credits left") }
            if let raw = credits.balance,
               raw.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
               let balance = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
               !balance.isNaN, balance >= 0 {
                return (balance.formatted(.number.precision(.fractionLength(0...(balance <= 10 ? 2 : 0)))), "credits left")
            }
        }
        if let budget = snapshot.extraUsageBudget {
            return (budget.remainingAmount.formatted(.currency(code: budget.currencyCode)
                .precision(.fractionLength(0...(budget.remainingAmount <= 10 ? 2 : 0)))), "extra usage left")
        }
        return nil
    }

    public var estimate: String? {
        guard used < 100 else { return nil }
        if let forecast = projection.cycleRunForecast {
            return "estimate \(Int(forecast.lowProjectedUsedPercentAtReset))–\(Int(forecast.highProjectedUsedPercentAtReset))%"
        }
        return projection.projectedUsedPercentAtReset.map { "estimate \(Int($0))%" } ?? "Collecting history"
    }
}

private struct RemainingBalanceOverlay: View {
    let amount: String
    let caption: String

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.5)
                if geometry.size.height < 44 {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(amount).font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(caption).font(.system(size: 9))
                    }
                    .padding(.horizontal, 3)
                } else {
                    VStack(spacing: 2) {
                        Text(amount)
                            .font(.system(size: min(36, max(16, geometry.size.height * 0.3)), weight: .semibold, design: .rounded))
                        Text(caption).font(.system(size: min(13, max(9, geometry.size.height * 0.16))))
                    }
                    .padding(4)
                }
            }
            .foregroundStyle(.white)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(amount) \(caption)")
    }
}

private struct UsageSparkline: View {
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let showForecast: Bool
    let historyColor: Color
    var body: some View {
        Canvas { context, size in
            guard let first = samples.first, let last = samples.last else { return }
            let end = showForecast ? projection.resetDate ?? last.capturedAt : last.capturedAt
            let span = max(1, end.timeIntervalSince(first.capturedAt))
            func point(_ date: Date, _ percent: Double) -> CGPoint {
                CGPoint(x: date.timeIntervalSince(first.capturedAt) / span * size.width,
                        y: size.height - min(130, max(0, percent)) / 130 * max(1, size.height - 3) - 1)
            }
            var path = Path()
            path.move(to: point(first.capturedAt, first.usedPercent))
            for sample in samples.dropFirst() { path.addLine(to: point(sample.capturedAt, sample.usedPercent)) }
            context.stroke(path, with: .color(historyColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let latest = point(last.capturedAt, last.usedPercent)
            context.fill(Path(ellipseIn: CGRect(x: max(0, latest.x - 2), y: latest.y - 2, width: 4, height: 4)), with: .color(historyColor))
            if showForecast, let estimate = projection.cycleRunForecast?.highProjectedUsedPercentAtReset
                ?? projection.projectedUsedPercentAtReset {
                var forecast = Path()
                forecast.move(to: point(last.capturedAt, last.usedPercent))
                forecast.addLine(to: point(end, estimate))
                context.stroke(forecast, with: .color(estimate > 100 ? .orange : .green), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .accessibilityLabel(projection.projectedUsedPercentAtReset == nil ? "Usage history" : "Usage history and forecast")
    }
}
