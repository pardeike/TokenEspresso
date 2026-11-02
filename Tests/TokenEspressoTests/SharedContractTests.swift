import Foundation
import XCTest
import TokenEspresso

final class SharedContractTests: XCTestCase {
    func testCreditContinuationRequiresKnownUnrestrictedCredit() {
        let cases: [(Bool, Bool, String?, Bool?, Bool)] = [
            (true, false, "12.5", false, true),
            (true, false, "0", false, false),
            (true, false, "-1", false, false),
            (true, false, "nan", false, false),
            (true, false, "1e309", false, false),
            (true, false, nil, false, false),
            (true, false, "1000", nil, false),
            (true, false, "1000", true, false),
            (false, true, nil, false, false),
            (true, true, nil, false, true),
        ]
        for (has, unlimited, balance, restricted, expected) in cases {
            XCTAssertEqual(CreditsSnapshot(hasCredits: has, unlimited: unlimited, balance: balance,
                overageLimitReached: restricted).canContinue, expected)
        }
    }

    func testReportingPreservesFractionalResetTimes() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000.75)
        let window = RateLimitWindow(usedPercent: 40, windowDurationMins: 10080, resetDate: reset)
        XCTAssertEqual(window.resetDate, reset)
        XCTAssertEqual(window.resetsAt, 1_800_000_000)
    }

    func testScopeMappingPreservesAccountAndModelPartitions() {
        XCTAssertEqual(UsageHistoryKeys.forecastScope(provider: "codex", window: "secondary", durationSeconds: 604800), "general")
        XCTAssertNil(UsageHistoryKeys.forecastScope(provider: "codex", window: "primary", durationSeconds: 18000))
        XCTAssertEqual(UsageHistoryKeys.forecastScope(provider: "claude", window: "model-name:fable", durationSeconds: 604800), "model-name:fable")
        XCTAssertEqual(UsageHistoryKeys.limitID(provider: "codex", scope: "general"), "codex")
        XCTAssertEqual(UsageHistoryKeys.limitID(provider: "claude", scope: "model:sonnet"), "model:sonnet")
        XCTAssertNotEqual(UsageHistoryKeys.account(provider: "Claude", identity: "one"), UsageHistoryKeys.account(provider: "Claude", identity: "two"))
        XCTAssertNotEqual(UsageHistoryKeys.historyFilename(scope: "general"), UsageHistoryKeys.historyFilename(scope: "model:sonnet"))
    }
}
