import Foundation

public struct CodexRateLimitsResponse: Codable, Equatable, Sendable {
    public let rateLimits: RateLimitSnapshot
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    public init(rateLimits: RateLimitSnapshot, rateLimitsByLimitId: [String: RateLimitSnapshot]? = nil) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }

    public var codexSnapshot: RateLimitSnapshot {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }
}

public struct RateLimitSnapshot: Codable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
    public let credits: CreditsSnapshot?
    public let planType: String?
    public let rateLimitReachedType: String?
    public let extraUsageBudget: ExtraUsageBudget?

    public init(
        limitId: String?,
        limitName: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        credits: CreditsSnapshot?,
        planType: String?,
        rateLimitReachedType: String?,
        extraUsageBudget: ExtraUsageBudget? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
        self.extraUsageBudget = extraUsageBudget
    }
}

/// Remaining spending allowance, separate from a prepaid credit balance.
public struct ExtraUsageBudget: Codable, Equatable, Sendable {
    public let remainingAmount: Decimal
    public let currencyCode: String

    public init(remainingAmount: Decimal, currencyCode: String) {
        self.remainingAmount = remainingAmount
        self.currencyCode = currencyCode
    }
}

public struct RateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Int?
    private let preciseResetTimestamp: Double?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Int?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
        self.preciseResetTimestamp = nil
    }

    public init(usedPercent: Double, windowDurationMins: Int?, resetDate: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        let timestamp = resetDate?.timeIntervalSince1970
        self.preciseResetTimestamp = timestamp.flatMap { $0.isFinite ? $0 : nil }
        self.resetsAt = timestamp.flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    public var resetDate: Date? {
        preciseResetTimestamp.map(Date.init(timeIntervalSince1970:)) ?? resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public struct CreditsSnapshot: Codable, Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?
    public let overageLimitReached: Bool?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?, overageLimitReached: Bool? = nil) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
        self.overageLimitReached = overageLimitReached
    }

    /// A positive balance alone does not establish permission to continue beyond the subscription allowance.
    public var canContinue: Bool {
        guard hasCredits, overageLimitReached == false else { return false }
        if unlimited { return true }
        guard let balance, let amount = Double(balance), amount.isFinite else { return false }
        return amount > 0
    }
}
