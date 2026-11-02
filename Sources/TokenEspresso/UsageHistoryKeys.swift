import CryptoKit
import Foundation

/// Pure keys for existing account-partitioned histories. Callers choose root directories and CloudKit containers.
public enum UsageHistoryKeys {
    public static func account(provider: String, identity: String) -> String { hash(provider + ":" + identity) }
    public static func historyFilename(scope: String) -> String { hash(scope) + ".jsonl" }
    public static func cloudZone(accountKey: String, scope: String) -> String { hash(accountKey + ":" + scope) }
    public static func limitID(provider: String, scope: String) -> String {
        provider == "codex" && scope == "general" ? "codex" : scope
    }

    public static func forecastScope(provider: String, window: String, durationSeconds: Double?) -> String? {
        guard durationSeconds == 604800 else { return nil }
        if provider == "codex" { return ["primary", "secondary"].contains(window) ? "general" : nil }
        guard provider == "claude" else { return nil }
        if window == "seven_day" { return "general" }
        return window.hasPrefix("model:") || window.hasPrefix("model-name:") ? window : nil
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
