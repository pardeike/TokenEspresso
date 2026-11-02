# TokenEspresso

TokenEspresso is a Swift package for subscription usage allowances. It models a usage window as a percentage with a reset date, keeps a history of readings, predicts where usage will land at the next reset, and draws the result in SwiftUI. Provider clients for Codex and Claude usage endpoints are included as a separate product, but the core works on any reading you supply.

Requires Swift 6, macOS 14 or iOS 17.

| Product | Import | What it gives you |
| --- | --- | --- |
| TokenEspresso | `import TokenEspresso` | Snapshot and sample models, history codec and file store, continuity checks, prediction policies, forecast engine |
| TokenEspressoProviders | `import TokenEspressoProviders` | Device-code sign-in and usage client for Codex, pasted-code PKCE client for Claude, HTTP and credential-store protocols |
| TokenEspressoUI | `import TokenEspressoUI` | `UsagePredictionView` and `UsageHistoryChart` |

The core and UI products do not depend on the providers product. You can decode history, run predictions and render views without any network code in your build.

## Install

In Xcode, choose File > Add Package Dependencies, enter `https://github.com/pardeike/TokenEspresso`, and pick the products your app needs.

In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/pardeike/TokenEspresso.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "TokenEspresso", package: "TokenEspresso"),
            .product(name: "TokenEspressoUI", package: "TokenEspresso"),
        ]
    ),
]
```

## Quick start

A reading is a `RateLimitSnapshot`. Its `secondary` window is the long one that predictions work on, typically seven days. Its `primary` window is the short one, typically five hours. Each stored reading is a `QuotaSample`.

```swift
import TokenEspresso

let now = Date()
let reset = now.addingTimeInterval(3 * 24 * 3600)

let snapshot = RateLimitSnapshot(
    limitId: "codex",
    limitName: nil,
    primary: RateLimitWindow(usedPercent: 12, windowDurationMins: 300,
                             resetDate: now.addingTimeInterval(3600)),
    secondary: RateLimitWindow(usedPercent: 42, windowDurationMins: 10_080,
                               resetDate: reset),
    credits: nil,
    planType: "pro",
    rateLimitReachedType: nil
)

// Earlier readings from the same window, oldest first. In a real app these
// come from a QuotaSampleStore. Here they are synthesized.
let history = (0...48).map { hour in
    QuotaSample(
        capturedAt: now.addingTimeInterval(Double(hour - 48) * 3600),
        limitId: "codex", limitName: nil,
        usedPercent: Double(hour) * 0.8,
        windowMinutes: 10_080, resetsAt: reset, planType: "pro"
    )
}

let prediction = UsagePredictionEngine.evaluate(snapshot: snapshot, samples: history, now: now)

prediction.projection.paceState                  // .noData, .fine, .watch or .slowDown
prediction.projection.projectedUsedPercentAtReset // Double? estimate at reset
prediction.evidence.status                       // .available, .insufficientHistory, ...
```

Then show it:

```swift
import SwiftUI
import TokenEspresso
import TokenEspressoUI

struct AllowanceCard: View {
    let snapshot: RateLimitSnapshot
    let history: [QuotaSample]
    let prediction: UsagePrediction

    var body: some View {
        UsagePredictionView(
            title: "Weekly allowance",
            snapshot: snapshot,
            samples: history,
            prediction: prediction,
            accent: .accentColor
        )
        .frame(height: 180)
    }
}
```

The view draws the history line, a forecast corridor, the 100% line and the reset time. It starts no timers and makes no requests. You decide when to fetch a new reading and pass it in.

## Recording history

Predictions need a trail of readings from the current window. Convert each fetched snapshot into a sample and append it to a `QuotaSampleStore`, which writes one JSON object per line.

```swift
let store = QuotaSampleStore(fileURL: historyURL)

if let sample = QuotaSample(snapshot: snapshot, capturedAt: Date()) {
    try store.append(sample)
}

let history = try store.load()   // keeps 14 days and at most 25 000 samples by default
```

`QuotaSample(snapshot:capturedAt:)` returns nil when the snapshot has no secondary window. Timestamps are rounded to whole seconds so that samples from different devices merge cleanly. `store.merge(_:)` combines samples from another source with the local file and removes duplicates.

### Guarding against bad readings

Weekly usage only rises inside a window. A reading that is suddenly lower is either a real reset or a glitch. `QuotaSnapshotContinuityPolicy` tells the two apart by waiting for confirmation before it accepts a drop. It also holds back a single unexpectedly high reading until a second one agrees.

```swift
let boot = QuotaSnapshotContinuityPolicy.bootstrap(from: history)
var continuity = QuotaSnapshotContinuityPolicy(
    trustedSnapshot: boot?.snapshot,
    isCorroborated: boot?.isCorroborated ?? true
)

switch continuity.evaluate(fresh, capturedAt: Date()) {
case .accepted(let observations):
    for observation in observations {
        if let sample = QuotaSample(snapshot: observation.snapshot, capturedAt: observation.capturedAt) {
            try store.append(sample)
        }
    }
case .pending:
    break   // not enough evidence yet, keep polling
}
```

A reset needs three agreeing readings over at least 90 seconds. Keep the `continuity` value alive between polls, since it carries the pending candidates.

### Sharing history files

`UsageHistoryCodec` is the file format. Dates are ISO 8601, one sample per line. Decoding rejects a malformed line by default and can skip instead.

```swift
let data = try UsageHistoryCodec.encode(samples)
let strict = try UsageHistoryCodec.decode(data)
let lenient = try UsageHistoryCodec.decode(data, malformedLines: .skip)
```

A plain `JSONEncoder` with default date encoding does not produce this format. Use the codec when another app or a sync service needs to read the file.

`UsageHistoryKeys` derives stable, hashed names for per-account files and sync zones without touching storage:

```swift
let accountKey = UsageHistoryKeys.account(provider: "claude", identity: profile.identity)
let filename = UsageHistoryKeys.historyFilename(scope: "general")   // "<sha256>.jsonl"
let zone = UsageHistoryKeys.cloudZone(accountKey: accountKey, scope: "general")
```

The provider, identity and scope strings are hashed byte for byte. They are case-sensitive, and every writer and reader of the same history must pass them identically. The package does not normalize case or guess a provider's naming convention, because a silent rewrite would split one account's history into two.

You choose the root directory, the account registry and any cloud container. Credentials never belong in history files.

## Predicting

`UsagePredictionEngine.evaluate` takes a snapshot, the stored samples and a policy. It returns a `UsagePrediction` with three parts:

- `projection` holds the numbers to draw: current percent, ideal pace, an estimate at reset, and an optional `cycleRunForecast` with low and high paths.
- `evidence` says how much to trust it, with a `status` and a machine-readable `reason`.
- `samples` are the readings that actually matched the current window.

### Two policies

`.display` is the default. It always returns something drawable. When the window's readings give the pattern engine enough to work with, the projection carries a provisional optimistic and pessimistic path. When they do not, it falls back to a linear pace estimate from the readings so far. Either way, `evidence` reports independently. It can say `.insufficientHistory` or `.staleHistory` next to a line that is still drawn, so a card can show the line and label it "collecting history". Use it for charts and cards.

`.verifiedReporting` suppresses estimates the evidence does not support. Samples must match the snapshot's limit id, window length, reset time and plan. There must be at least three of them spanning at least an hour. The latest must be at most 30 minutes old. Usage must be nondecreasing and must not exceed the live value. If any check fails, the projection carries no estimate and `evidence.reason` names the gap. Use it when a number will be acted on, logged or reported, and a confident wrong answer is worse than none.

Both policies run the same pattern engine. `.display` adds the linear fallback. `.verifiedReporting` adds the gate. In `UsagePredictionView`, a `status` you pass always wins over the evidence-derived footer text.

| `evidence.status` | Meaning |
| --- | --- |
| `.available` | Forecast present, evidence passed |
| `.insufficientHistory` | Too few samples, too short a span, or no usage increase yet |
| `.staleHistory` | Newest matching sample is older than 30 minutes |
| `.exhausted` | Usage is at 100% |
| `.unavailable` | No usable window, or history does not match the live reading |

### At 100%

When the secondary window reaches 100% there is nothing left to forecast. The projection has no estimate, `paceState` is `.slowDown`, and `UsagePredictionView` replaces the forecast with a balance overlay if one is available.

Two kinds of balance exist and they are not interchangeable:

- `CreditsSnapshot` is a prepaid credit balance in credit units. `canContinue` is true only when credits exist, the overage limit is not reached, and the balance is unlimited or positive.
- `ExtraUsageBudget` is remaining monthly spending headroom in a currency. It is a limit on extra spending, not money already paid.

The view formats amounts above 10 as whole numbers and amounts up to 10 with at most two decimals.

### Lower-level pieces

`QuotaForecaster` is the engine underneath. It works on any nondecreasing series and knows nothing about dates or providers:

```swift
let result = try QuotaForecaster().forecast(observed: [0, 2, 2, 5, 9, 9, 12], totalCount: 14)
result.optimistic.endpoint
result.pessimistic.endpoint
result.pessimistic.quotaExhaustionIndex   // first index at or above 100, or nil
```

`UsagePredictionEngine.crossingDate(in:)` finds when a forecast path reaches a limit:

```swift
if let forecast = prediction.projection.cycleRunForecast {
    let worstCase = UsagePredictionEngine.crossingDate(in: forecast.highLineSegments)
}
```

`QuotaForecastDiagnosticExporter.makeDiagnosticsData(snapshot:samples:now:)` returns pretty-printed JSON with the inputs, parameters and both scenario paths. Attach it to bug reports when a forecast looks wrong.

## Provider clients

`TokenEspressoProviders` contains clients for two usage endpoints. Both take caller-supplied provider configuration, including the client identifier. The package ships no identifier, registers no client and grants no provider access. Those are yours to arrange.

Both clients are plain structs with explicit async methods. Nothing runs until you call it. You own credential storage, you decide when to refresh, and you make sure only one refresh per grant is in flight at a time.

### Codex

Sign-in uses the device-code flow. Credentials go through a `CodexCredentialStore` that you supply. A Keychain implementation is included.

```swift
import TokenEspresso
import TokenEspressoProviders

let configuration = CodexConfiguration(clientID: "<your client id>")
let http = EphemeralUsageHTTPClient()
let store = KeychainCodexCredentialStore(service: "com.example.myapp.codex")
let auth = CodexAuthentication(configuration: configuration, httpClient: http, tokenStore: store)

/// First run. Show the code, then wait for the user to finish in the browser.
func signIn() async throws -> CodexCredentials {
    let device = try await auth.requestDeviceCode()
    print("Open \(device.verificationURL) and enter \(device.userCode)")
    return try await auth.completeDeviceCodeLogin(device)   // polls, then saves to the store
}

/// Later runs. Reuse stored credentials and refresh them when they are old.
func fetchSnapshot() async throws -> RateLimitSnapshot {
    guard let tokens = try await auth.validTokens(refreshIfNeeded: true) else {
        throw CodexAuthenticationError.needsSignIn
    }
    let usage = CodexUsageClient(configuration: configuration, httpClient: http)
    let response = try await usage.fetchRateLimits(tokens: tokens)
    return response.codexSnapshot
}
```

`response.rateLimitsByLimitId` holds additional metered features when the account has them. `auth.accountSnapshot(for:)` reads the email and plan from the ID token for display. `auth.logout()` deletes the stored credentials.

`KeychainCodexCredentialStore` requires an explicit service name. It reads and writes only that item.

### Claude

The Claude client implements the provider's pasted-code PKCE flow: the browser shows a code, the user pastes it back into your app. It is not a general OAuth library.

```swift
import TokenEspressoProviders

let configuration = ClaudeOAuthConfiguration(clientID: "<your client id>")
let client = ClaudeOAuthClient(configuration: configuration)

// 1. Start. Keep `pending` until the user returns. It expires after 30 minutes.
let pending = ClaudeAuthorization()
let url = client.authorizationURL(for: pending)    // open this in the browser

// 2. The browser shows "code#state". The user pastes it.
let credentials = try await client.complete(pending, input: pastedText)
// Persist `credentials` now. The client does not store anything.

// 3. Use it.
let profile = try await client.profile(accessToken: credentials.accessToken)
let reading = try await client.usage(accessToken: credentials.accessToken)

// 4. Refresh before expiry. Persist the result before the next request.
if credentials.needsRefresh() {
    let refreshed = try await client.refresh(credentials)
}
```

`profile.identity` is a stable account identifier suitable for `UsageHistoryKeys.account(provider: "claude", identity:)`.

A Claude reading can carry several seven-day windows: one general and one per model. Each is a `ClaudeUsageDiagram` with its own id. Build one snapshot per diagram and keep one history per id:

```swift
let snapshots = reading.diagrams.map { diagram in
    RateLimitSnapshot(
        limitId: diagram.id,
        limitName: diagram.title,
        primary: reading.session,
        secondary: RateLimitWindow(usedPercent: diagram.usedPercent,
                                   windowDurationMins: diagram.windowMinutes,
                                   resetDate: diagram.resetsAt),
        credits: nil,
        planType: nil,
        rateLimitReachedType: nil,
        extraUsageBudget: reading.extraUsageBudget
    )
}
```

If you fetch the usage JSON yourself, `ClaudeUsageReading.decode(_:)` lives in the core product and needs no provider import.

### HTTP transport

Both clients talk through the `UsageHTTPClient` protocol, which has one method. `EphemeralUsageHTTPClient` is the default: no cookies, no cache, no redirects, a 128 KB response cap, a 20 second request timeout and a 30 second resource timeout. `URLSessionUsageHTTPClient(session:)` wraps a session you configure. Implementing the protocol yourself is the easiest way to mock responses in tests.

## SwiftUI views

`UsagePredictionView` is a complete card. `UsageHistoryChart` is just the chart.

```swift
UsagePredictionView(
    title: "Opus",
    provider: "Claude",
    snapshot: snapshot,
    samples: history,
    prediction: prediction,   // optional, the view computes the display policy if nil
    style: .detail,           // .detail, .preview or .micro
    status: nil,              // overrides the footer, for example "Signed out"
    accent: .accentColor
)
```

- `.detail` shows the large percentage, an estimate range, the full chart with day bands and forecast corridor, and the reset time.
- `.preview` shows a sparkline with a dashed forecast line.
- `.micro` fits a menu bar or widget row: title, percentage and a thin sparkline.

Pass `accent` from your app's accent color. It tints the title and the history line. Pass `prediction` when you already computed one so the view does not recompute it. When `status` is nil and the evidence says `.staleHistory`, the footer reads "Stale history".

For long histories, `UsageHistorySampler.displaySamples(from:)` thins the samples to at most 480 points while keeping the first and last.

## Command line

The package also includes `quota-forecast` for forecasting a cumulative series from JSON:

```sh
swift run quota-forecast --input Examples/observed.json --output forecast.json
swift run quota-forecast --help
```

## Development

```sh
Scripts/verify.sh          # macOS tests, then iOS builds of both UI and Providers
Scripts/verify.sh --macos  # macOS tests only
```

The script prints `ok` on success and keeps full logs in `.build/logs/`. CI runs the same script.

## License

MIT. See LICENSE.
