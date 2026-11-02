import Foundation
import SwiftUI
import Charts
import TokenEspresso

public struct UsageHistoryChart: View {
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let snapshot: RateLimitSnapshot?
    let now: Date
    var historyColor: Color = .accentColor

    public init(samples: [QuotaSample], projection: QuotaProjection, snapshot: RateLimitSnapshot?,
                now: Date = Date(), historyColor: Color = .accentColor) {
        self.samples = samples
        self.projection = projection
        self.snapshot = snapshot
        self.now = now
        self.historyColor = historyColor
    }

    @Environment(\.self) private var environment

    public var body: some View {
        if let resetDate = projection.resetDate {
            let startDate = resetDate.addingTimeInterval(-Double(snapshot?.secondary?.windowDurationMins ?? 10_080) * 60)
            let shortWindow = (snapshot?.secondary?.windowDurationMins ?? 10_080) < 1440
            let dayBands = shortWindow ? [] : QuotaGraphTimeAxis.dayBands(startDate: startDate, resetDate: resetDate)
            let plotStartDate = dayBands.first?.startDate ?? startDate
            let plotEndDate = dayBands.last?.endDate ?? resetDate
            let palette = QuotaGraphPerceptualPalette(
                plotBase: QuotaGraphLinearRGB(
                    resolved: plotBackground.resolve(in: environment)
                )
            )
            Chart {
                ForEach(dayBands) { band in
                    RectangleMark(
                        xStart: .value("Start", band.startDate),
                        xEnd: .value("End", band.endDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(band.isLight ? palette.lightDay.color : palette.darkDay.color)
                }

                ForEach(
                    QuotaGraphTimeAxis.intensityBands(
                        runs: projection.cycleRunForecast?.observedIntensityRuns ?? [],
                        dayBands: dayBands,
                        startDate: startDate,
                        resetDate: resetDate
                    )
                ) { band in
                    RectangleMark(
                        xStart: .value("Intensity Start", band.startDate),
                        xEnd: .value("Intensity End", band.endDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(
                        band.isLight ? palette.lightIntensity.color : palette.darkIntensity.color
                    )
                }

                if plotStartDate < startDate {
                    RectangleMark(
                        xStart: .value("Before Window", plotStartDate),
                        xEnd: .value("Window Start", startDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(outsideWindowColor)
                }

                if resetDate < plotEndDate {
                    RectangleMark(
                        xStart: .value("Window End", resetDate),
                        xEnd: .value("After Window", plotEndDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(outsideWindowColor)
                }

                ForEach(QuotaGraphTimeAxis.dayBoundaries(startDate: plotStartDate, resetDate: plotEndDate)) { boundary in
                    RuleMark(x: .value("Day", boundary.date))
                        .foregroundStyle(.secondary.opacity(0.16))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }

                RuleMark(x: .value("Window Start", startDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .butt))

                ForEach(actualPoints) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Percent", point.percent),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(historyColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                ForEach(actualPoints) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Percent", point.percent)
                    )
                    .foregroundStyle(historyColor)
                    .symbolSize(12)
                }

                if projection.cycleRunForecast == nil,
                   let projected = projection.projectedUsedPercentAtReset {
                    ForEach(projectionSegments(now: now, resetDate: resetDate, projected: projected)) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Percent", point.percent),
                                series: .value("Series", segment.id)
                            )
                            .foregroundStyle(segment.color)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        }
                    }
                }

                RuleMark(
                    xStart: .value("Limit Start", startDate),
                    xEnd: .value("Limit End", resetDate),
                    y: .value("Limit", 100)
                )
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                RuleMark(x: .value("Deadline", resetDate))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .butt))
            }
            .chartXScale(domain: plotStartDate ... plotEndDate)
            .chartYScale(domain: 0 ... graphCeiling)
            .chartXAxis {
                if shortWindow {
                    AxisMarks(values: .stride(by: .hour)) {
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.system(size: 9))
                    }
                }
            }
            .chartXAxis(shortWindow ? .visible : .hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.32))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.4))
                    if let number = value.as(Double.self) {
                        AxisValueLabel {
                            Text("\(Int(number))")
                                .font(.system(size: 9, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .offset(y: number == 0 ? -4 : 0)
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(palette.plotBase.color)
                    .overlay {
                        if let cycleForecast = projection.cycleRunForecast {
                            CycleForecastCorridorOverlay(
                                forecast: cycleForecast,
                                plotStartDate: plotStartDate,
                                plotEndDate: plotEndDate,
                                ceiling: graphCeiling
                            )
                            .allowsHitTesting(false)
                        }
                    }
            }
            .clipped()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.35))
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actualPoints: [GraphPoint] {
        QuotaGraphObservedSeries.points(
            from: samples,
            currentUsedPercent: snapshot?.secondary?.usedPercent,
            now: now
        ).map {
            GraphPoint(date: $0.date, percent: graphPercent($0.usedPercent), series: "actual")
        }
    }

    private func projectionSegments(now: Date, resetDate: Date, projected: Double) -> [ProjectionSegment] {
        let current = projection.currentUsedPercent
        let totalDuration = resetDate.timeIntervalSince(now)
        guard totalDuration > 0,
              current < graphCeiling else {
            return []
        }

        let startPoint = GraphPoint(date: now, percent: graphPercent(current), series: "projected-safe")
        let visibleEndPoint = visibleProjectionEndPoint(
            now: now,
            resetDate: resetDate,
            current: current,
            projected: projected
        )

        if current >= 100 {
            return [ProjectionSegment(id: "projected-over", color: Color.red.opacity(0.6), points: [startPoint, visibleEndPoint])]
        }

        if projected <= current {
            return [ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, visibleEndPoint])]
        }

        guard projected > 100 else {
            return [ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, visibleEndPoint])]
        }

        let crossingFraction = (100 - current) / (projected - current)
        let crossingDate = now.addingTimeInterval(totalDuration * crossingFraction)
        let crossingPoint = GraphPoint(date: crossingDate, percent: 100, series: "projected-crossing")
        return [
            ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, crossingPoint]),
            ProjectionSegment(id: "projected-over", color: Color.red.opacity(0.6), points: [crossingPoint, visibleEndPoint])
        ]
    }

    private func visibleProjectionEndPoint(
        now: Date,
        resetDate: Date,
        current: Double,
        projected: Double
    ) -> GraphPoint {
        guard projected > graphCeiling,
              projected > current else {
            return GraphPoint(date: resetDate, percent: graphPercent(projected), series: "projected-limit")
        }

        let totalDuration = resetDate.timeIntervalSince(now)
        let ceilingFraction = (graphCeiling - current) / (projected - current)
        let ceilingDate = now.addingTimeInterval(totalDuration * ceilingFraction)
        return GraphPoint(date: ceilingDate, percent: graphCeiling, series: "projected-ceiling")
    }

    private func graphPercent(_ value: Double) -> Double {
        min(graphCeiling, max(0, value))
    }

    private var plotBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var outsideWindowColor: Color {
        Color.black.opacity(0.62)
    }

    private var graphCeiling: Double {
        let projectedHigh = projection.cycleRunForecast?.highProjectedUsedPercentAtReset
            ?? projection.projectedUsedPercentAtReset
            ?? projection.currentUsedPercent
        guard projectedHigh > 100 else {
            return 105
        }
        let roundedHeadroom = ((projectedHigh - 100) / 10).rounded(.up) * 10
        return min(130, max(105, 100 + roundedHeadroom / 2))
    }
}

enum QuotaGraphTimeAxis {
    private static let cycleDuration: TimeInterval = 24 * 60 * 60

    static func dayBands(
        startDate: Date,
        resetDate: Date,
        calendar: Calendar = .current
    ) -> [QuotaGraphDayBand] {
        guard startDate < resetDate else {
            return []
        }

        var bands: [QuotaGraphDayBand] = []
        var bandStart = cycleBoundary(onOrBefore: startDate, calendar: calendar)
        var index = 0

        while bandStart < resetDate {
            let bandEnd = bandStart.addingTimeInterval(cycleDuration)
            bands.append(
                QuotaGraphDayBand(
                    index: index,
                    startDate: bandStart,
                    endDate: bandEnd,
                    isLight: index.isMultiple(of: 2)
                )
            )

            bandStart = bandEnd
            index += 1
        }

        return bands
    }

    static func dayBoundaries(
        startDate: Date,
        resetDate: Date,
        calendar: Calendar = .current
    ) -> [QuotaGraphDayBoundary] {
        guard startDate < resetDate else {
            return []
        }

        var boundaries: [QuotaGraphDayBoundary] = []
        var boundary = cycleBoundary(onOrBefore: startDate, calendar: calendar)
            .addingTimeInterval(cycleDuration)
        var index = 0

        while boundary < resetDate {
            boundaries.append(QuotaGraphDayBoundary(index: index, date: boundary))
            boundary = boundary.addingTimeInterval(cycleDuration)
            index += 1
        }

        return boundaries
    }

    static func intensityBands(
        runs: [QuotaForecastRun],
        dayBands: [QuotaGraphDayBand],
        startDate: Date,
        resetDate: Date
    ) -> [QuotaGraphIntensityBand] {
        guard startDate < resetDate,
              dayBands.isEmpty == false else {
            return []
        }

        var intensityBands: [QuotaGraphIntensityBand] = []
        for run in runs {
            let runStart = max(startDate, run.startDate)
            let runEnd = min(resetDate, run.endDate)
            guard runEnd.timeIntervalSince(runStart) >= 60 else {
                continue
            }

            for dayBand in dayBands {
                let segmentStart = max(runStart, dayBand.startDate)
                let segmentEnd = min(runEnd, dayBand.endDate)
                guard segmentStart < segmentEnd else {
                    continue
                }

                intensityBands.append(
                    QuotaGraphIntensityBand(
                        index: intensityBands.count,
                        startDate: segmentStart,
                        endDate: segmentEnd,
                        isLight: dayBand.isLight
                    )
                )
            }
        }
        return intensityBands
    }

    private static func cycleBoundary(onOrBefore date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }
}

struct QuotaGraphDayBand: Equatable, Identifiable {
    let index: Int
    let startDate: Date
    let endDate: Date
    let isLight: Bool

    var id: Int { index }
}

struct QuotaGraphDayBoundary: Equatable, Identifiable {
    let index: Int
    let date: Date

    var id: Int { index }
}

struct QuotaGraphIntensityBand: Equatable, Identifiable {
    let index: Int
    let startDate: Date
    let endDate: Date
    let isLight: Bool

    var id: Int { index }
}

struct QuotaGraphObservedPoint: Equatable, Sendable {
    let date: Date
    let usedPercent: Double
}

enum QuotaGraphObservedSeries {
    static func points(
        from samples: [QuotaSample],
        currentUsedPercent: Double?,
        now: Date
    ) -> [QuotaGraphObservedPoint] {
        var points = samples
            .sorted { $0.capturedAt < $1.capturedAt }
            .map {
                QuotaGraphObservedPoint(
                    date: $0.capturedAt,
                    usedPercent: $0.usedPercent
                )
            }

        guard let currentUsedPercent else {
            return points
        }

        guard let last = points.last else {
            return [QuotaGraphObservedPoint(date: now, usedPercent: currentUsedPercent)]
        }

        if last.date < now {
            points.append(QuotaGraphObservedPoint(date: now, usedPercent: currentUsedPercent))
        }
        return points
    }
}

private struct ProjectionSegment: Identifiable {
    let id: String
    let color: Color
    let points: [GraphPoint]
}

private struct GraphPoint: Identifiable {
    let date: Date
    let percent: Double
    let series: String

    var id: String {
        "\(series)-\(date.timeIntervalSince1970)"
    }
}

private struct CycleForecastCorridorOverlay: View {
    let forecast: QuotaCycleRunForecast
    let plotStartDate: Date
    let plotEndDate: Date
    let ceiling: Double

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard size.width > 0,
                      size.height > 0,
                      plotEndDate > plotStartDate else {
                    return
                }

                let lowSegments = forecast.lowLineSegments.isEmpty
                    ? forecast.lineSegments
                    : forecast.lowLineSegments
                let highSegments = forecast.highLineSegments.isEmpty
                    ? forecast.lineSegments
                    : forecast.highLineSegments
                guard lowSegments.isEmpty == false,
                      highSegments.isEmpty == false else {
                    return
                }

                let safeRange = 0.0 ... limitPercent
                let overLimitRange = (limitPercent + percentEpsilon) ... ceiling
                let safeLowLine = linePath(from: lowSegments, visiblePercentRange: safeRange, in: size)
                let safeHighLine = linePath(from: highSegments, visiblePercentRange: safeRange, in: size)
                let overLimitLowLine = linePath(from: lowSegments, visiblePercentRange: overLimitRange, in: size)
                let overLimitHighLine = linePath(from: highSegments, visiblePercentRange: overLimitRange, in: size)
                let fill = splitFillPaths(between: lowSegments, and: highSegments, in: size)

                var safeFillContext = context
                safeFillContext.opacity = corridorOpacity
                safeFillContext.drawLayer { layer in
                    layer.fill(fill.safe, with: .color(predictionFillColor))
                }

                context.stroke(safeLowLine, with: .color(predictionLowerLineColor), style: lineStyle)
                context.stroke(safeHighLine, with: .color(predictionUpperLineColor), style: lineStyle)

                var overLimitFillContext = context
                overLimitFillContext.opacity = overLimitOpacity
                overLimitFillContext.drawLayer { layer in
                    layer.fill(fill.overLimit, with: .color(.red))
                }

                context.stroke(overLimitLowLine, with: .color(.red), style: lineStyle)
                context.stroke(overLimitHighLine, with: .color(.red), style: lineStyle)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func linePath(
        from segments: [QuotaForecastLineSegment],
        visiblePercentRange: ClosedRange<Double>,
        in size: CGSize
    ) -> Path {
        var path = Path()
        let sortedSegments = segments
            .sorted { $0.startDate < $1.startDate }
            .filter { $0.endDate > $0.startDate }
        var previousEndPoint: CGPoint?
        for segment in sortedSegments {
            guard let clipped = clippedLineInterval(segment, to: visiblePercentRange) else {
                previousEndPoint = nil
                continue
            }

            let startPoint = plotPoint(date: clipped.startDate, percent: clipped.startPercent, in: size)
            let endPoint = plotPoint(date: clipped.endDate, percent: clipped.endPercent, in: size)
            if let previousEndPoint,
               distance(from: previousEndPoint, to: startPoint) < 0.5 {
                path.addLine(to: startPoint)
            } else {
                path.move(to: startPoint)
            }
            path.addLine(to: endPoint)
            previousEndPoint = endPoint
        }
        return path
    }

    private func clippedLineInterval(
        _ segment: QuotaForecastLineSegment,
        to visiblePercentRange: ClosedRange<Double>
    ) -> ForecastLineInterval? {
        let startPercent = segment.startUsedPercent
        let endPercent = segment.endUsedPercent
        let lowerBound = visiblePercentRange.lowerBound
        let upperBound = visiblePercentRange.upperBound
        let minimumPercent = min(startPercent, endPercent)
        let maximumPercent = max(startPercent, endPercent)
        guard maximumPercent >= lowerBound,
              minimumPercent <= upperBound else {
            return nil
        }

        let percentDelta = endPercent - startPercent
        var startProgress = 0.0
        var endProgress = 1.0

        if abs(percentDelta) <= percentEpsilon {
            guard visiblePercentRange.contains(startPercent) else {
                return nil
            }
        } else if percentDelta > 0 {
            startProgress = max(startProgress, (lowerBound - startPercent) / percentDelta)
            endProgress = min(endProgress, (upperBound - startPercent) / percentDelta)
        } else {
            startProgress = max(startProgress, (upperBound - startPercent) / percentDelta)
            endProgress = min(endProgress, (lowerBound - startPercent) / percentDelta)
        }

        startProgress = min(1, max(0, startProgress))
        endProgress = min(1, max(0, endProgress))
        guard endProgress >= startProgress else {
            return nil
        }

        let segmentDuration = segment.endDate.timeIntervalSince(segment.startDate)
        return ForecastLineInterval(
            startDate: segment.startDate.addingTimeInterval(segmentDuration * startProgress),
            endDate: segment.startDate.addingTimeInterval(segmentDuration * endProgress),
            startPercent: startPercent + percentDelta * startProgress,
            endPercent: startPercent + percentDelta * endProgress
        )
    }

    private func distance(from firstPoint: CGPoint, to secondPoint: CGPoint) -> Double {
        let xDistance = firstPoint.x - secondPoint.x
        let yDistance = firstPoint.y - secondPoint.y
        return sqrt(xDistance * xDistance + yDistance * yDistance)
    }

    private func splitFillPaths(
        between firstSegments: [QuotaForecastLineSegment],
        and secondSegments: [QuotaForecastLineSegment],
        in size: CGSize
    ) -> ForecastSplitFillPaths {
        let firstSorted = firstSegments.sorted { $0.startDate < $1.startDate }
        let secondSorted = secondSegments.sorted { $0.startDate < $1.startDate }
        let dates = splitDates(firstSorted + secondSorted, firstSegments: firstSorted, secondSegments: secondSorted)

        return ForecastSplitFillPaths(
            safe: fillPath(
                for: dates,
                firstSegments: firstSorted,
                secondSegments: secondSorted,
                visiblePercentRange: 0 ... limitPercent,
                in: size
            ),
            overLimit: fillPath(
                for: dates,
                firstSegments: firstSorted,
                secondSegments: secondSorted,
                visiblePercentRange: limitPercent ... ceiling,
                in: size
            )
        )
    }

    private func fillPath(
        for dates: [Date],
        firstSegments: [QuotaForecastLineSegment],
        secondSegments: [QuotaForecastLineSegment],
        visiblePercentRange: ClosedRange<Double>,
        in size: CGSize
    ) -> Path {
        var runs: [[ForecastBandPoint]] = []
        var currentRun: [ForecastBandPoint] = []

        for date in dates {
            guard let point = visibleBandPoint(
                date: date,
                firstSegments: firstSegments,
                secondSegments: secondSegments,
                visiblePercentRange: visiblePercentRange,
                in: size
            ) else {
                if currentRun.isEmpty == false {
                    runs.append(currentRun)
                    currentRun = []
                }
                continue
            }
            currentRun.append(point)
        }

        if currentRun.isEmpty == false {
            runs.append(currentRun)
        }

        var path = Path()
        for run in runs where run.count >= 2 {
            path.addPath(fillPath(from: run))
        }
        return path
    }

    private func fillPath(from fillPoints: [ForecastBandPoint]) -> Path {
        var path = Path()
        guard let firstPoint = fillPoints.first else {
            return path
        }

        path.move(to: CGPoint(x: firstPoint.x, y: firstPoint.topY))
        for point in fillPoints.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.topY))
        }
        for point in fillPoints.reversed() {
            path.addLine(to: CGPoint(x: point.x, y: point.bottomY))
        }
        path.closeSubpath()
        return path
    }

    private func visibleBandPoint(
        date: Date,
        firstSegments: [QuotaForecastLineSegment],
        secondSegments: [QuotaForecastLineSegment],
        visiblePercentRange: ClosedRange<Double>,
        in size: CGSize
    ) -> ForecastBandPoint? {
        guard let firstPercent = percent(at: date, in: firstSegments),
              let secondPercent = percent(at: date, in: secondSegments) else {
            return nil
        }

        let lowerPercent = min(firstPercent, secondPercent)
        let upperPercent = max(firstPercent, secondPercent)
        let visibleLowerPercent = max(lowerPercent, visiblePercentRange.lowerBound)
        let visibleUpperPercent = min(upperPercent, visiblePercentRange.upperBound)
        guard visibleUpperPercent + percentEpsilon >= visibleLowerPercent else {
            return nil
        }

        let band = visibleBand(
            firstY: y(percent: visibleUpperPercent, in: size),
            secondY: y(percent: visibleLowerPercent, in: size),
            in: size
        )
        return ForecastBandPoint(
            x: x(date: date, in: size),
            topY: band.topY,
            bottomY: band.bottomY
        )
    }

    private func plotPoint(date: Date, percent: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: x(date: date, in: size),
            y: y(percent: percent, in: size)
        )
    }

    private func x(date: Date, in size: CGSize) -> Double {
        let duration = plotEndDate.timeIntervalSince(plotStartDate)
        let fraction = date.timeIntervalSince(plotStartDate) / duration
        return min(1, max(0, fraction)) * size.width
    }

    private func y(percent: Double, in size: CGSize) -> Double {
        let value = min(ceiling, max(0, percent))
        return size.height * (1 - value / ceiling)
    }

    private func visibleBand(firstY: Double, secondY: Double, in size: CGSize) -> ForecastBandPointY {
        var topY = min(firstY, secondY)
        var bottomY = max(firstY, secondY)
        guard bottomY - topY < forecastLineWidth else {
            return ForecastBandPointY(topY: topY, bottomY: bottomY)
        }

        let centerY = (topY + bottomY) / 2
        topY = centerY - forecastLineWidth / 2
        bottomY = centerY + forecastLineWidth / 2
        if topY < 0 {
            bottomY = min(size.height, bottomY - topY)
            topY = 0
        }
        if bottomY > size.height {
            topY = max(0, topY - (bottomY - size.height))
            bottomY = size.height
        }
        return ForecastBandPointY(topY: topY, bottomY: bottomY)
    }

    private func percent(at date: Date, in segments: [QuotaForecastLineSegment]) -> Double? {
        guard let first = segments.first else {
            return nil
        }
        if date <= first.startDate {
            return first.startUsedPercent
        }

        for segment in segments {
            if date <= segment.startDate {
                return segment.startUsedPercent
            }
            if date <= segment.endDate {
                let duration = segment.endDate.timeIntervalSince(segment.startDate)
                guard duration > 0 else {
                    return segment.endUsedPercent
                }
                let progress = date.timeIntervalSince(segment.startDate) / duration
                return segment.startUsedPercent + (segment.endUsedPercent - segment.startUsedPercent) * progress
            }
        }

        return segments.last?.endUsedPercent
    }

    private func uniqueDates(_ dates: [Date]) -> [Date] {
        var unique: [Date] = []
        for date in dates.sorted() {
            guard let last = unique.last,
                  abs(date.timeIntervalSince(last)) < 0.5 else {
                unique.append(date)
                continue
            }
        }
        return unique
    }

    private func splitDates(
        _ segments: [QuotaForecastLineSegment],
        firstSegments: [QuotaForecastLineSegment],
        secondSegments: [QuotaForecastLineSegment]
    ) -> [Date] {
        var dates = segments.flatMap { [$0.startDate, $0.endDate] }
        dates += segments.compactMap { crossingDate(in: $0, at: limitPercent) }
        dates += segments.compactMap { crossingDate(in: $0, at: ceiling) }

        for date in dates {
            guard let firstPercent = percent(at: date, in: firstSegments),
                  let secondPercent = percent(at: date, in: secondSegments) else {
                continue
            }
            if min(firstPercent, secondPercent) < limitPercent,
               max(firstPercent, secondPercent) > limitPercent {
                dates.append(date)
            }
        }
        return uniqueDates(dates)
    }

    private func crossingDate(
        in segment: QuotaForecastLineSegment,
        at percent: Double
    ) -> Date? {
        let startPercent = segment.startUsedPercent
        let endPercent = segment.endUsedPercent
        guard (startPercent < percent && endPercent > percent)
                || (startPercent > percent && endPercent < percent) else {
            return nil
        }

        let percentDelta = endPercent - startPercent
        guard abs(percentDelta) > 0.0001 else {
            return nil
        }

        let progress = (percent - startPercent) / percentDelta
        return segment.startDate.addingTimeInterval(
            segment.endDate.timeIntervalSince(segment.startDate) * progress
        )
    }

    private var lineStyle: StrokeStyle {
        StrokeStyle(lineWidth: forecastLineWidth, lineCap: .round, lineJoin: .round)
    }

    private var predictionFillColor: Color {
        Color(red: 0.12, green: 0.56, blue: 0.94)
    }

    private var predictionLowerLineColor: Color {
        Color(red: 0.063, green: 0.725, blue: 0.506)
    }

    private var predictionUpperLineColor: Color {
        Color(red: 0.961, green: 0.620, blue: 0.043)
    }

    private let corridorOpacity = 0.24
    private let overLimitOpacity = 0.42
    private let forecastLineWidth = 2.4
    private let limitPercent = 100.0
    private let percentEpsilon = 0.0001
}

private struct ForecastBandPoint {
    let x: Double
    let topY: Double
    let bottomY: Double
}

private struct ForecastBandPointY {
    let topY: Double
    let bottomY: Double
}

private struct ForecastSplitFillPaths {
    let safe: Path
    let overLimit: Path
}

private struct ForecastLineInterval {
    let startDate: Date
    let endDate: Date
    let startPercent: Double
    let endPercent: Double
}

private extension DateFormatter {
    @MainActor
    static let panelDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    @MainActor
    static let panelTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
