import Foundation
import TokenEspresso

public enum CodexAuthenticationError: Error, LocalizedError, Sendable {
    case needsSignIn
    case unauthorized
    case loginTimedOut
    case invalidResponse(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .needsSignIn:
            "Codex needs ChatGPT sign-in."
        case .unauthorized:
            "Codex sign-in expired."
        case .loginTimedOut:
            "Codex sign-in timed out."
        case let .invalidResponse(message):
            "Invalid Codex auth response: \(message)"
        case let .server(message):
            message
        }
    }
}

public struct CodexDeviceAuthorization: Equatable, Sendable {
    public let deviceAuthId: String
    public let userCode: String
    public let verificationURL: URL
    public let interval: TimeInterval
}

public struct CodexAuthentication: Sendable {
    private let configuration: CodexConfiguration
    private let httpClient: UsageHTTPClient
    private let tokenStore: CodexCredentialStore

    public init(
        configuration: CodexConfiguration,
        httpClient: UsageHTTPClient,
        tokenStore: CodexCredentialStore
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.tokenStore = tokenStore
    }

    public func validTokens(refreshIfNeeded: Bool) async throws -> CodexCredentials? {
        guard let tokens = try await tokenStore.load() else {
            return nil
        }

        guard refreshIfNeeded, shouldRefresh(tokens) else {
            return tokens
        }

        return try await refreshStoredTokens(tokens)
    }

    public func requestDeviceCode() async throws -> CodexDeviceAuthorization {
        var request = URLRequest(url: configuration.deviceUserCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(DeviceUserCodeRequest(clientId: configuration.clientID))

        do {
            let data = try await httpClient.validatedData(for: request)
            let response = try JSONDecoder().decode(DeviceUserCodeResponse.self, from: data)
            return CodexDeviceAuthorization(
                deviceAuthId: response.deviceAuthId,
                userCode: response.userCode,
                verificationURL: configuration.deviceVerificationURL,
                interval: TimeInterval(response.interval.value)
            )
        } catch let error as UsageHTTPError {
            throw mapHTTPError(error)
        } catch let error as DecodingError {
            throw CodexAuthenticationError.invalidResponse(error.localizedDescription)
        } catch {
            throw error
        }
    }

    public func completeDeviceCodeLogin(_ deviceCode: CodexDeviceAuthorization) async throws -> CodexCredentials {
        let startedAt = Date()
        while true {
            try Task.checkCancellation()
            if Date().timeIntervalSince(startedAt) >= configuration.deviceLoginTimeout {
                throw CodexAuthenticationError.loginTimedOut
            }

            if let code = try await pollDeviceCode(deviceCode) {
                let tokens = try await exchangeCodeForTokens(code)
                try await tokenStore.save(tokens)
                return tokens
            }

            let interval = configuration.devicePollIntervalOverride ?? max(1, deviceCode.interval)
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    public func refreshStoredTokens() async throws -> CodexCredentials {
        guard let tokens = try await tokenStore.load() else {
            throw CodexAuthenticationError.needsSignIn
        }
        return try await refreshStoredTokens(tokens)
    }

    public func accountSnapshot(for tokens: CodexCredentials) -> CodexAccountSnapshot {
        let claims = CodexTokenClaims.parse(tokens.idToken)
        return CodexAccountSnapshot(type: "chatgpt", email: claims.email, planType: claims.planType)
    }

    public func logout() async throws {
        try await tokenStore.delete()
    }

    private func pollDeviceCode(_ deviceCode: CodexDeviceAuthorization) async throws -> DeviceTokenSuccessResponse? {
        var request = URLRequest(url: configuration.deviceTokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(DeviceTokenRequest(
            deviceAuthId: deviceCode.deviceAuthId,
            userCode: deviceCode.userCode
        ))

        let (data, statusCode) = try await httpClient.statusData(for: request)
        if (200..<300).contains(statusCode) {
            do {
                return try JSONDecoder().decode(DeviceTokenSuccessResponse.self, from: data)
            } catch {
                throw CodexAuthenticationError.invalidResponse(error.localizedDescription)
            }
        }

        if statusCode == 403 || statusCode == 404 {
            return nil
        }

        throw CodexAuthenticationError.server("Device-code login failed with HTTP \(statusCode).")
    }

    private func exchangeCodeForTokens(_ code: DeviceTokenSuccessResponse) async throws -> CodexCredentials {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = codexFormURLEncoded([
            ("grant_type", "authorization_code"),
            ("code", code.authorizationCode),
            ("redirect_uri", configuration.deviceCallbackURL.absoluteString),
            ("client_id", configuration.clientID),
            ("code_verifier", code.codeVerifier),
        ])

        do {
            let data = try await httpClient.validatedData(for: request)
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard let idToken = response.idToken,
                  let accessToken = response.accessToken,
                  let refreshToken = response.refreshToken else {
                throw CodexAuthenticationError.invalidResponse("Token exchange response was missing tokens.")
            }
            return CodexCredentials(
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: refreshToken,
                lastRefresh: Date()
            )
        } catch let error as UsageHTTPError {
            throw mapHTTPError(error)
        } catch let error as DecodingError {
            throw CodexAuthenticationError.invalidResponse(error.localizedDescription)
        } catch {
            throw error
        }
    }

    private func refreshStoredTokens(_ tokens: CodexCredentials) async throws -> CodexCredentials {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(TokenRefreshRequest(
            clientId: configuration.clientID,
            grantType: "refresh_token",
            refreshToken: tokens.refreshToken
        ))

        do {
            let data = try await httpClient.validatedData(for: request)
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            let refreshed = CodexCredentials(
                idToken: response.idToken ?? tokens.idToken,
                accessToken: response.accessToken ?? tokens.accessToken,
                refreshToken: response.refreshToken ?? tokens.refreshToken,
                lastRefresh: Date()
            )
            try await tokenStore.save(refreshed)
            return refreshed
        } catch let error as UsageHTTPError {
            if case let .unexpectedStatus(status) = error,
               status == 400 || status == 401 || status == 403 {
                try await tokenStore.delete()
                throw CodexAuthenticationError.needsSignIn
            }
            throw mapHTTPError(error)
        } catch let error as DecodingError {
            throw CodexAuthenticationError.invalidResponse(error.localizedDescription)
        } catch {
            throw error
        }
    }

    private func shouldRefresh(_ tokens: CodexCredentials) -> Bool {
        if Date().timeIntervalSince(tokens.lastRefresh) >= configuration.tokenRefreshInterval {
            return true
        }

        guard let expiration = CodexTokenClaims.parse(tokens.accessToken).expiration else {
            return false
        }
        return expiration.timeIntervalSinceNow <= configuration.accessTokenRefreshSkew
    }

    private func mapHTTPError(_ error: UsageHTTPError) -> CodexAuthenticationError {
        switch error {
        case let .invalidResponse(message):
            .invalidResponse(message)
        case let .unexpectedStatus(status):
            if status == 401 {
                .unauthorized
            } else if status == 404 {
                .server("Codex device-code login is unavailable.")
            } else {
                .server("HTTP \(status)")
            }
        }
    }
}

private struct DeviceUserCodeRequest: Encodable {
    let clientId: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
    }
}

private struct DeviceUserCodeResponse: Decodable {
    let deviceAuthId: String
    let userCode: String
    let interval: FlexibleInt

    enum CodingKeys: String, CodingKey {
        case deviceAuthId = "device_auth_id"
        case userCode = "user_code"
        case usercode
        case interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthId = try container.decode(String.self, forKey: .deviceAuthId)
        userCode = try container.decodeIfPresent(String.self, forKey: .userCode)
            ?? container.decode(String.self, forKey: .usercode)
        interval = try container.decodeIfPresent(FlexibleInt.self, forKey: .interval) ?? FlexibleInt(value: 5)
    }
}

private struct DeviceTokenRequest: Encodable {
    let deviceAuthId: String
    let userCode: String

    enum CodingKeys: String, CodingKey {
        case deviceAuthId = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct DeviceTokenSuccessResponse: Decodable {
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }
}

private struct TokenRefreshRequest: Encodable {
    let clientId: String
    let grantType: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
    }
}

private struct TokenResponse: Decodable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
