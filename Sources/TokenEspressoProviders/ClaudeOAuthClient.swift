import CryptoKit
import Foundation
import TokenEspresso

public enum ClaudeOAuthError: Error, Equatable, Sendable {
    case invalidCode, expiredAuthorization, invalidResponse
    case httpStatus(Int)
}

public struct ClaudeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) <= 60 }
}

public struct ClaudeOAuthConfiguration: Sendable {
    public let clientID: String
    public let authorizationURL: URL
    public let tokenURL: URL
    public let resourceBaseURL: URL
    public let redirectURL: URL
    public let userAgent: String

    public init(clientID: String,
                authorizationURL: URL = URL(string: "https://claude.com/cai/oauth/authorize")!,
                tokenURL: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
                resourceBaseURL: URL = URL(string: "https://api.anthropic.com/api/oauth")!,
                redirectURL: URL = URL(string: "https://platform.claude.com/oauth/code/callback")!,
                userAgent: String = "TokenEspresso") {
        self.clientID = clientID
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.resourceBaseURL = resourceBaseURL
        self.redirectURL = redirectURL
        self.userAgent = userAgent
    }
}

/// The caller stores this pending grant until the user returns the browser's code#state.
public struct ClaudeAuthorization: Codable, Sendable {
    public let verifier: String
    public let state: String
    public let createdAt: Date

    public init(now: Date = Date()) {
        verifier = Self.random()
        state = Self.random()
        createdAt = now
    }

    public init(verifier: String, state: String, createdAt: Date) {
        self.verifier = verifier
        self.state = state
        self.createdAt = createdAt
    }

    public func code(from input: String, now: Date = Date()) throws -> String {
        guard (0..<1800).contains(now.timeIntervalSince(createdAt)) else { throw ClaudeOAuthError.expiredAuthorization }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1] == state else { throw ClaudeOAuthError.invalidCode }
        return String(parts[0])
    }

    private static func random() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL
    }
}

public struct ClaudeProfile: Equatable, Sendable {
    public let identity: String
    public let email: String?

    public static func decode(_ data: Data) throws -> ClaudeProfile {
        struct Profile: Decodable {
            struct Account: Decodable {
                let uuid: String
                let email: String?
                let email_address: String?
                let emailAddress: String?
            }
            struct Organization: Decodable { let uuid: String }
            let account: Account
            let organization: Organization
        }
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        guard let identity = UsageHistoryContract.claudeIdentity(
            organizationID: profile.organization.uuid, accountID: profile.account.uuid) else {
            throw ClaudeOAuthError.invalidResponse
        }
        return ClaudeProfile(identity: identity,
            email: profile.account.email ?? profile.account.email_address ?? profile.account.emailAddress)
    }
}

public struct ClaudeTokenResponse: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Double
    public let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope
    }

    public init(accessToken: String, refreshToken: String?, expiresIn: Double, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.scope = scope
    }

    public func credentials(previousRefreshToken: String? = nil, now: Date = Date()) throws -> ClaudeCredentials {
        guard !accessToken.isEmpty, let refresh = refreshToken ?? previousRefreshToken, !refresh.isEmpty,
              expiresIn.isFinite, expiresIn > 0,
              scope == nil || scope!.split(separator: " ").contains("user:profile") else { throw ClaudeOAuthError.invalidResponse }
        return ClaudeCredentials(accessToken: accessToken, refreshToken: refresh, expiresAt: now.addingTimeInterval(expiresIn))
    }
}

/// Explicit operations only. The caller serializes refreshes and persists rotated credentials before further requests.
public struct ClaudeOAuthClient: Sendable {
    public let configuration: ClaudeOAuthConfiguration
    private let http: any UsageHTTPClient

    public init(configuration: ClaudeOAuthConfiguration, http: any UsageHTTPClient = EphemeralUsageHTTPClient()) {
        self.configuration = configuration
        self.http = http
    }

    public static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }

    public func authorizationURL(for pending: ClaudeAuthorization) -> URL {
        var url = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
        url.queryItems = ["code": "true", "client_id": configuration.clientID,
            "response_type": "code", "redirect_uri": configuration.redirectURL.absoluteString,
            "scope": "user:profile", "code_challenge": Self.challenge(pending.verifier),
            "code_challenge_method": "S256", "state": pending.state]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    public func complete(_ pending: ClaudeAuthorization, input: String, now: Date = Date()) async throws -> ClaudeCredentials {
        try await token(["grant_type": "authorization_code", "code": pending.code(from: input, now: now),
            "state": pending.state, "redirect_uri": configuration.redirectURL.absoluteString,
            "client_id": configuration.clientID, "code_verifier": pending.verifier], now: now)
    }

    public func refresh(_ credential: ClaudeCredentials, now: Date = Date()) async throws -> ClaudeCredentials {
        try await token(["grant_type": "refresh_token", "refresh_token": credential.refreshToken,
            "client_id": configuration.clientID, "scope": "user:profile"], previous: credential.refreshToken, now: now)
    }

    public func profile(accessToken: String) async throws -> ClaudeProfile {
        try ClaudeProfile.decode(await resource("profile", accessToken: accessToken))
    }

    public func usage(accessToken: String) async throws -> ClaudeUsageReading {
        try ClaudeUsageReading.decode(await resource("usage", accessToken: accessToken))
    }

    private func token(_ body: [String: String], previous: String? = nil, now: Date) async throws -> ClaudeCredentials {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await response(request)
        return try JSONDecoder().decode(ClaudeTokenResponse.self, from: data).credentials(previousRefreshToken: previous, now: now)
    }

    private func resource(_ name: String, accessToken: String) async throws -> Data {
        var request = URLRequest(url: configuration.resourceBaseURL.appendingPathComponent(name))
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        return try await response(request)
    }

    private func response(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        guard response.statusCode == 200 else { throw ClaudeOAuthError.httpStatus(response.statusCode) }
        guard data.count <= 131_072 else { throw ClaudeOAuthError.invalidResponse }
        return data
    }

    public static func failureCode(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error"] as? String ?? (object["error"] as? [String: Any])?["type"] as? String,
              ["invalid_grant", "invalid_request", "invalid_scope", "unauthorized_client",
               "unsupported_grant_type", "access_denied", "server_error", "temporarily_unavailable",
               "authentication_error", "permission_error", "rate_limit_error"].contains(code) else { return nil }
        return code
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
