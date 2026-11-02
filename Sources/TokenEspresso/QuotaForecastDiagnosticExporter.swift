import Foundation

public enum QuotaForecastDiagnosticExporter {
    public static func makeDiagnosticsData(
        snapshot: RateLimitSnapshot?,
        samples: [QuotaSample],
        now: Date = Date(),
        generatedAt: Date = Date(),
        syncStatusDescription: String? = nil
    ) throws -> Data {
        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        let packageContext = makePackageContext(snapshot: snapshot, samples: samples, now: now)
        let firstInputOffsetSeconds = packageContext.input.flatMap { input in
            input.observedDates.first.map { $0.timeIntervalSince(input.weeklyStartDate) }
        }
        let lastInputOffsetSeconds = packageContext.input.flatMap { input in
            input.observedDates.last.map { $0.timeIntervalSince(input.weeklyStartDate) }
        }
        let packageResult: QuotaForecast?
        let packageError: String?

        if let input = packageContext.input {
            if input.hasUsageIncreases {
                do {
                    packageResult = try QuotaForecastKitAdapter.forecast(input)
                    packageError = nil
                } catch {
                    packageResult = nil
                    packageError = error.localizedDescription
                }
            } else {
                packageResult = nil
                packageError = "No usage increases found in forecast input."
            }
        } else {
            packageResult = nil
            packageError = packageContext.errorDescription
        }

        let payload = QuotaForecastDiagnosticsPayload(
            generatedAt: generatedAt,
            now: now,
            syncStatus: syncStatusDescription,
            window: packageContext.window,
            samples: ForecastSampleSummary(
                storedSampleCount: samples.count,
                currentWindowSampleCount: packageContext.currentWindowSampleCount,
                inputSampleCount: packageContext.input?.observedValues.count ?? 0,
                firstInputOffsetSeconds: firstInputOffsetSeconds,
                lastInputOffsetSeconds: lastInputOffsetSeconds
            ),
            display: ForecastDisplaySummary(
                currentUsedPercent: projection.currentUsedPercent,
                fallbackProjectedWeeklyUsedPercentAtReset: projection.projectedUsedPercentAtReset,
                displayedLowProjectedWeeklyUsedPercentAtReset: projection.cycleRunForecast?.lowProjectedUsedPercentAtReset
                    ?? projection.projectedUsedPercentAtReset,
                displayedHighProjectedWeeklyUsedPercentAtReset: projection.cycleRunForecast?.highProjectedUsedPercentAtReset
                    ?? projection.projectedUsedPercentAtReset,
                paceState: projection.paceState.rawValue
            ),
            packageParameters: QuotaForecastKitAdapter.parametersSummary(
                for: packageContext.input?.configuration ?? QuotaForecastKitAdapter.defaultConfiguration()
            ),
            packageInput: packageContext.input,
            packageResult: packageResult,
            packageError: packageError
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func makePackageContext(
        snapshot: RateLimitSnapshot?,
        samples: [QuotaSample],
        now: Date
    ) -> ForecastPackageContext {
        guard let snapshot else {
            return ForecastPackageContext(
                window: nil,
                currentWindowSampleCount: 0,
                input: nil,
                errorDescription: "No quota snapshot."
            )
        }

        guard let weekly = snapshot.secondary else {
            return ForecastPackageContext(
                window: nil,
                currentWindowSampleCount: 0,
                input: nil,
                errorDescription: "Quota snapshot has no weekly window."
            )
        }

        let current = weekly.usedPercent
        guard let resetDate = weekly.resetDate,
              let durationMinutes = weekly.windowDurationMins,
              durationMinutes > 0 else {
            return ForecastPackageContext(
                window: nil,
                currentWindowSampleCount: 0,
                input: nil,
                errorDescription: "Quota snapshot has no valid weekly reset/window duration."
            )
        }

        let startDate = resetDate.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        let elapsedWindowSeconds = now.timeIntervalSince(startDate)
        let currentWindowSamples = QuotaProjectionEngine.currentWindowSamples(
            snapshot: snapshot,
            startDate: startDate,
            resetDate: resetDate,
            now: now,
            samples: samples
        )
        let input = QuotaForecastKitAdapter.makeForecastInput(
            current: current,
            startDate: startDate,
            resetDate: resetDate,
            now: now,
            samples: currentWindowSamples
        )

        return ForecastPackageContext(
            window: ForecastWindowSummary(
                weeklyStartDate: startDate,
                resetDate: resetDate,
                windowMinutes: durationMinutes,
                elapsedWindowSeconds: elapsedWindowSeconds
            ),
            currentWindowSampleCount: currentWindowSamples.count,
            input: input,
            errorDescription: input == nil ? "No usable forecast input." : nil
        )
    }
}

private struct ForecastPackageContext {
    let window: ForecastWindowSummary?
    let currentWindowSampleCount: Int
    let input: QuotaForecastKitInput?
    let errorDescription: String?
}

private struct QuotaForecastDiagnosticsPayload: Encodable {
    let generatedAt: Date
    let now: Date
    let syncStatus: String?
    let window: ForecastWindowSummary?
    let samples: ForecastSampleSummary
    let display: ForecastDisplaySummary
    let packageParameters: QuotaForecastKitParameterSummary
    let packageInput: QuotaForecastKitInput?
    let packageResult: QuotaForecast?
    let packageError: String?
}

private struct ForecastWindowSummary: Encodable {
    private enum CodingKeys: String, CodingKey {
        case weeklyStartDate, elapsedWindowSeconds
        case resetDate = "weeklyResetDate"
        case windowMinutes = "weeklyWindowMinutes"
    }
    let weeklyStartDate: Date
    let resetDate: Date
    let windowMinutes: Int
    let elapsedWindowSeconds: TimeInterval
}

private struct ForecastSampleSummary: Encodable {
    let storedSampleCount: Int
    let currentWindowSampleCount: Int
    let inputSampleCount: Int
    let firstInputOffsetSeconds: Double?
    let lastInputOffsetSeconds: Double?
}

private struct ForecastDisplaySummary: Encodable {
    private enum CodingKeys: String, CodingKey {
        case currentUsedPercent = "currentWeeklyUsedPercent"
        case fallbackProjectedWeeklyUsedPercentAtReset, displayedLowProjectedWeeklyUsedPercentAtReset
        case displayedHighProjectedWeeklyUsedPercentAtReset, paceState
    }
    let currentUsedPercent: Double
    let fallbackProjectedWeeklyUsedPercentAtReset: Double?
    let displayedLowProjectedWeeklyUsedPercentAtReset: Double?
    let displayedHighProjectedWeeklyUsedPercentAtReset: Double?
    let paceState: String
}
