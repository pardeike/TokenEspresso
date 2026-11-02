# TokenEspresso

- Use `Scripts/verify.sh` before publishing. It runs macOS tests and builds both products for iOS.
- Use `Scripts/verify.sh --macos` for focused work that does not affect iOS compatibility.
- Keep full output in ignored `.build/logs/`. Print `ok` only after all requested checks pass.
- Keep credentials and credential storage under caller control. Never search another application's credentials.
- Never change persisted history keys or identity matching during a source extraction.
- Views consume data. They must not start timers, authentication, network requests, or storage operations.
- Keep the core product independent of SwiftUI and AppKit.
- Verify public examples with imports that do not use `@testable`.
