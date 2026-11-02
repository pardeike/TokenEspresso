import Foundation
import TokenEspresso

public struct CodexConfiguration: Sendable {
    public let issuerBaseURL: URL
    public let backendBaseURL: URL
    public let clientID: String
    public let deviceLoginTimeout: TimeInterval
    public let tokenRefreshInterval: TimeInterval
    public let accessTokenRefreshSkew: TimeInterval
    public let devicePollIntervalOverride: TimeInterval?
    public let userAgent: String

    public init(issuerBaseURL: URL = URL(string: "https://auth.openai.com")!,
                backendBaseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
                clientID: String,
                deviceLoginTimeout: TimeInterval = 900, tokenRefreshInterval: TimeInterval = 691200,
                accessTokenRefreshSkew: TimeInterval = 300, devicePollIntervalOverride: TimeInterval? = nil,
                userAgent: String = "TokenEspresso") {
        self.issuerBaseURL = issuerBaseURL
        self.backendBaseURL = backendBaseURL
        self.clientID = clientID
        self.deviceLoginTimeout = deviceLoginTimeout
        self.tokenRefreshInterval = tokenRefreshInterval
        self.accessTokenRefreshSkew = accessTokenRefreshSkew
        self.devicePollIntervalOverride = devicePollIntervalOverride
        self.userAgent = userAgent
    }

    public var deviceUserCodeURL: URL {
        issuerBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("accounts")
            .appendingPathComponent("deviceauth")
            .appendingPathComponent("usercode")
    }

    public var deviceTokenURL: URL {
        issuerBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("accounts")
            .appendingPathComponent("deviceauth")
            .appendingPathComponent("token")
    }

    public var deviceVerificationURL: URL {
        issuerBaseURL
            .appendingPathComponent("codex")
            .appendingPathComponent("device")
    }

    public var deviceCallbackURL: URL {
        issuerBaseURL
            .appendingPathComponent("deviceauth")
            .appendingPathComponent("callback")
    }

    public var tokenURL: URL {
        issuerBaseURL
            .appendingPathComponent("oauth")
            .appendingPathComponent("token")
    }

    public var usageURL: URL {
        if backendBaseURL.path.contains("/backend-api") {
            return backendBaseURL.appendingPathComponent("wham").appendingPathComponent("usage")
        }
        return backendBaseURL.appendingPathComponent("api").appendingPathComponent("codex").appendingPathComponent("usage")
    }
}

public struct CodexCredentials: Codable, Equatable, Sendable {
    public init(idToken: String, accessToken: String, refreshToken: String, lastRefresh: Date) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.lastRefresh = lastRefresh
    }

    public let idToken: String
    public let accessToken: String
    public let refreshToken: String
    public let lastRefresh: Date
}

public protocol CodexCredentialStore: Sendable {
    func load() async throws -> CodexCredentials?
    func save(_ tokens: CodexCredentials) async throws
    func delete() async throws
}

public protocol UsageHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionUsageHTTPClient: UsageHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageHTTPError.invalidResponse("Response was not HTTP.")
        }
        return (data, httpResponse)
    }
}

public enum UsageHTTPError: Error, LocalizedError, Sendable {
    case invalidResponse(String)
    case unexpectedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidResponse(message):
            message
        case let .unexpectedStatus(status):
            "HTTP \(status)"
        }
    }
}

extension UsageHTTPClient {
    func validatedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await self.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw UsageHTTPError.unexpectedStatus(response.statusCode)
        }
        return data
    }

    func statusData(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await self.data(for: request)
        return (data, response.statusCode)
    }
}

public struct CodexTokenClaims: Sendable {
    public let expiration: Date?
    public let email: String?
    public let planType: String?
    public let accountID: String?
    public let isFedRAMP: Bool

    public static func parse(_ jwt: String) -> CodexTokenClaims {
        guard let payload = decodePayload(jwt),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return CodexTokenClaims(expiration: nil, email: nil, planType: nil, accountID: nil, isFedRAMP: false)
        }

        let profile = object["https://api.openai.com/profile"] as? [String: Any]
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        let expiration = (object["exp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        let email = object["email"] as? String ?? profile?["email"] as? String
        let accountID = auth?["chatgpt_account_id"] as? String
        let planType = auth?["chatgpt_plan_type"] as? String
        let isFedRAMP = auth?["chatgpt_account_is_fedramp"] as? Bool ?? false

        return CodexTokenClaims(
            expiration: expiration,
            email: email,
            planType: planType,
            accountID: accountID,
            isFedRAMP: isFedRAMP
        )
    }

    private static func decodePayload(_ jwt: String) -> Data? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

struct FlexibleDouble: Decodable, Sendable {
    let value: Double

    init(value: Double) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let int = try? container.decode(Int.self) {
            self.value = Double(int)
        } else if let string = try? container.decode(String.self),
                  let double = Double(string) {
            self.value = double
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected numeric value.")
            )
        }
    }
}

struct FlexibleInt: Decodable, Sendable {
    let value: Int

    init(value: Int) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = Int(double)
        } else if let string = try? container.decode(String.self),
                  let int = Int(string) {
            self.value = int
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected integer value.")
            )
        }
    }
}

struct FlexibleString: Decodable, Sendable {
    let value: String

    init(value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self.value = string
        } else if let int = try? container.decode(Int.self) {
            self.value = String(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = String(double)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string value.")
            )
        }
    }
}

func codexFormURLEncoded(_ pairs: [(String, String)]) -> Data {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    let encoded = pairs
        .map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    return Data(encoded.utf8)
}
