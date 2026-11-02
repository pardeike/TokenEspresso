# TokenEspresso

Swift models, history, predictions, and provider clients for subscription usage.
TokenEspresso is extracted from TokenCoffee and BrrainzTools.

Requires Swift 6, macOS 14 or iOS 17.

| Product | Purpose |
| --- | --- |
| TokenEspresso | Usage models, history codec and continuity, storage keys, prediction policies, and credit availability |
| TokenEspressoProviders | Explicit authentication, credential-store interfaces, and usage clients |
| TokenEspressoUI | SwiftUI prediction view and history chart |

The core and UI do not depend on the providers product.
Creating a client or view starts no background work.

## Install

Add this repository as a Swift package dependency:

```swift
.package(url: "https://github.com/pardeike/TokenEspresso.git", branch: "main")
```

Select only the products your application uses.
The first versioned release will replace this development branch reference.

## Predict from supplied data

```swift
import TokenEspresso

let now = Date()
let window = RateLimitWindow(
    usedPercent: 40,
    windowDurationMins: 10_080,
    resetDate: now.addingTimeInterval(3 * 86_400)
)
let snapshot = RateLimitSnapshot(
    limitId: "codex", limitName: nil,
    primary: nil, secondary: window,
    credits: nil, planType: "pro", rateLimitReachedType: nil
)
let prediction = UsagePredictionEngine.evaluate(
    snapshot: snapshot, samples: history, now: now, policy: .display
)
```

Supply your own snapshots and history, or obtain them through a provider client.
Authentication is not required to decode history, calculate predictions, or render views.

The display policy retains a pace estimate while pattern history grows.
The verifiedReporting policy requires matching, fresh, nondecreasing observations before reporting a pattern forecast.
Both policies expose evidence and use the same pattern engine.
The display policy also provides the original linear fallback.
At 100%, the projection contains no future usage estimate.

## Render

```swift
import TokenEspressoUI

UsagePredictionView(
    title: "Weekly allowance",
    snapshot: snapshot,
    samples: history,
    prediction: prediction,
    now: now,
    accent: .accentColor
)
```

UsageHistoryChart provides the graph without the surrounding readout.
Views consume values and start no timers, storage operations, or network requests.
Pass the application's accent color.
A caller-supplied status takes precedence over the default stale-history status.

When the selected allowance reaches 100%, the default view removes the prediction.
If a balance is available, it dims the graph and shows that balance.
Amounts above 10 use whole numbers.
Smaller amounts retain up to two decimal places.
Codex balances are credit units.
Claude extra-usage amounts represent remaining monthly spending headroom in the reported currency.
They are not a prepaid credit balance.

## Authenticate or supply credentials

Import TokenEspressoProviders for CodexAuthentication, CodexUsageClient, and ClaudeOAuthClient.
Provide your HTTP client, credential store, or already authorized credentials as needed.
Provider configuration requires the caller's client identifier.
TokenEspresso does not register OAuth clients or grant provider access.

ClaudeOAuthClient implements the provider's pasted-code PKCE flow.
It is not a general-purpose OAuth implementation.
It returns credentials without choosing storage.
Retain your application's serialized credential representation.
Serialize refresh operations for each grant.
Persist a returned refresh token before making another request with it.

CodexAuthentication uses an injected CodexCredentialStore.
Its completed sign-in and refresh operations save through that store.
An actor or process lock in the host must own operations on each grant.
KeychainCodexCredentialStore requires an explicit service identifier.
No client searches for another application's credentials.

The default HTTP transport rejects redirects, disables cookies and caching, and limits response size.
A supplied HTTP client owns its transport policy.

## Share history

Use UsageHistoryCodec for shared ISO-8601 JSONL files.
It preserves the existing TokenCoffee history keys while exposing neutral property names.
Decoding rejects malformed lines by default.
The explicit skip policy supports recovery when a host requires it.
Default JSONEncoder date encoding is not the shared history format.

UsageHistoryKeys derives account, scope-file, and CloudKit-zone keys without accessing storage.
When reading an existing writer's data, retain its provider identifier and identity exactly.
The host chooses root directories, account registries, CloudKit containers, and environments.
Credentials never belong in history files.

## Verify

Run Scripts/verify.sh for macOS tests and iOS builds.
Use Scripts/verify.sh --macos during work limited to macOS.
Full logs are saved in .build/logs.
The command prints ok only when all requested checks pass.

Regression fixtures capture the original consumers' prediction results before migration.
Public API tests decode history and render the SwiftUI view without importing the providers module.

## License

MIT. See LICENSE.
