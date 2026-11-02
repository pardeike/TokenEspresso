import Foundation
import XCTest
@testable import TokenEspresso

final class MigrationParityTests: XCTestCase {
    func testFullDisplayProjectionMatchesOriginalSignedTokenCoffeeCore() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "display-golden", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let scenarios = try XCTUnwrap(root["cases"] as? [[String: Any]])
        for scenario in scenarios {
            let input = try inputs(scenario)
            let actual = UsagePredictionEngine.evaluate(snapshot: input.snapshot, samples: input.samples, now: input.now).projection
            let expected = try XCTUnwrap(scenario["projection"])
            XCTAssertEqual(try canonical(reflect(actual)), try canonical(expected), scenario["name"] as? String ?? "")
        }
    }

    func testReportingPolicyMatchesOriginalBrrainzToolsStatusesAndNumbers() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "display-golden", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let scenarios = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let reporting = try XCTUnwrap(Bundle.module.url(forResource: "reporting-golden", withExtension: "json"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reporting)) as? [String: [String: Any]])
        for scenario in scenarios {
            let name = try XCTUnwrap(scenario["name"] as? String)
            let input = try inputs(scenario)
            let result = UsagePredictionEngine.evaluate(snapshot: input.snapshot, samples: input.samples,
                now: input.now, policy: .verifiedReporting)
            let golden = try XCTUnwrap(expected[name])
            XCTAssertEqual(result.evidence.status.rawValue, golden["status"] as? String, name)
            XCTAssertEqual(result.evidence.reason, golden["reason"] as? String, name)
            if let forecast = result.projection.cycleRunForecast {
                let low = try XCTUnwrap(golden["optimistic"] as? [String: Any])
                let high = try XCTUnwrap(golden["pessimistic"] as? [String: Any])
                XCTAssertEqual(forecast.lowProjectedUsedPercentAtReset, low["usedPercentAtReset"] as? Double, name)
                XCTAssertEqual(forecast.highProjectedUsedPercentAtReset, high["usedPercentAtReset"] as? Double, name)
            } else { XCTAssertNil(result.projection.projectedUsedPercentAtReset) }
        }
    }

    private func inputs(_ scenario: [String: Any]) throws -> (snapshot: RateLimitSnapshot, samples: [QuotaSample], now: Date) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RateLimitSnapshot.self, from: canonical(XCTUnwrap(scenario["snapshot"])))
        let samples = try decoder.decode([QuotaSample].self, from: canonical(XCTUnwrap(scenario["samples"])))
        return (snapshot, samples, Date(timeIntervalSince1970: try XCTUnwrap(scenario["now"] as? Double)))
    }

    private func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func reflect(_ value: Any) -> Any {
        if let date = value as? Date { return date.timeIntervalSince1970 }
        if let value = value as? Double { return value }
        if let value = value as? Int { return value }
        if let value = value as? Bool { return value }
        if let value = value as? String { return value }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.map { reflect($0.value) } ?? NSNull() }
        if mirror.displayStyle == .collection { return mirror.children.map { reflect($0.value) } }
        if mirror.displayStyle == .enum { return String(describing: value) }
        return Dictionary(uniqueKeysWithValues: mirror.children.map { ($0.label ?? "", reflect($0.value)) })
    }
}
