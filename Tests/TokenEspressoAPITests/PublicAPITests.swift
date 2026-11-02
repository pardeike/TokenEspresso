import Foundation
import SwiftUI
import XCTest
import TokenEspresso
import TokenEspressoUI

final class PublicAPITests: XCTestCase {
    @MainActor func testThirdConsumerCanDecodePredictAndRenderWithoutProviderModule() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(86400)
        let snapshot = RateLimitSnapshot(limitId: "codex", limitName: nil, primary: nil,
            secondary: RateLimitWindow(usedPercent: 100, windowDurationMins: 10080, resetsAt: Int(reset.timeIntervalSince1970)),
            credits: CreditsSnapshot(hasCredits: true, unlimited: false, balance: "1000.75"), planType: "pro", rateLimitReachedType: nil)
        let sample = QuotaSample(capturedAt: now, limitId: "codex", limitName: nil, usedPercent: 100,
            windowMinutes: 10080, resetsAt: reset, planType: "pro")
        let history = try UsageHistoryCodec.decode(UsageHistoryCodec.encode([sample]))
        let prediction = UsagePredictionEngine.evaluate(snapshot: snapshot, samples: history, now: now)
        XCTAssertEqual(prediction.evidence.status, .exhausted)
        XCTAssertNil(prediction.projection.cycleRunForecast)
        let view = UsagePredictionView(title: "Allowance", snapshot: snapshot, samples: history,
            prediction: prediction, now: now, accent: .accentColor)
        let renderer = ImageRenderer(content: view.frame(width: 390, height: 240))
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 390)
        XCTAssertEqual(image.height, 240)
        XCTAssertEqual(view.remainingBalance?.amount, Decimal(1001).formatted(.number))
    }

    func testHistoryCodecPinsLegacyKeysAndRejectsMixedDateFormats() throws {
        let sample = QuotaSample(capturedAt: Date(timeIntervalSince1970: 1000), limitId: "codex", limitName: nil,
            usedPercent: 30, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 2000), planType: "pro")
        let data = try UsageHistoryCodec.encode([sample])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["weeklyUsedPercent"] as? Double, 30)
        XCTAssertNil(object["usedPercent"])
        XCTAssertEqual(try UsageHistoryCodec.decode(data), [sample])
        var mixed = data
        mixed.append(try JSONEncoder().encode(sample))
        mixed.append(0x0A)
        XCTAssertThrowsError(try UsageHistoryCodec.decode(mixed))
        XCTAssertEqual(try UsageHistoryCodec.decode(mixed, malformedLines: .skip), [sample])
    }
}
