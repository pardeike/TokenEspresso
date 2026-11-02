import Foundation
import XCTest
import TokenEspresso
import TokenEspressoProviders

final class ClaudeProviderTests: XCTestCase, @unchecked Sendable {
    func testConfiguredPKCEAndStateValidation() throws {
        let pending = ClaudeAuthorization(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            state: "expected-state", createdAt: Date(timeIntervalSince1970: 1000))
        let client = ClaudeOAuthClient(configuration: ClaudeOAuthConfiguration(clientID: "caller-client"))
        let components = try XCTUnwrap(URLComponents(url: client.authorizationURL(for: pending), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["client_id"], "caller-client")
        XCTAssertEqual(query["scope"], "user:profile")
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(try pending.code(from: "code#expected-state", now: Date(timeIntervalSince1970: 1100)), "code")
        XCTAssertThrowsError(try pending.code(from: "code#wrong", now: Date(timeIntervalSince1970: 1100)))
        XCTAssertThrowsError(try pending.code(from: "code#expected-state", now: Date(timeIntervalSince1970: 999)))
        XCTAssertThrowsError(try pending.code(from: "code#expected-state", now: Date(timeIntervalSince1970: 2800)))
    }

    func testRefreshReturnsValidatedRotationAtInjectedTimeWithoutStorage() async throws {
        let http = RecordingHTTP(status: 200, data: Data(#"{"access_token":"next-access","refresh_token":"next-refresh","expires_in":600,"scope":"user:profile"}"#.utf8))
        let client = ClaudeOAuthClient(configuration: ClaudeOAuthConfiguration(clientID: "caller-client"), http: http)
        let old = ClaudeCredentials(accessToken: "old", refreshToken: "previous", expiresAt: .distantPast)
        let next = try await client.refresh(old, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(next.accessToken, "next-access")
        XCTAssertEqual(next.refreshToken, "next-refresh")
        XCTAssertEqual(next.expiresAt, Date(timeIntervalSince1970: 1600))
        let captured = await http.request()
        let request = try XCTUnwrap(captured)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["client_id"], "caller-client")
        XCTAssertEqual(body["scope"], "user:profile")
        XCTAssertEqual(body["refresh_token"], "previous")
    }

    func testFailureRetainsStatusWithoutPrivateProviderBody() async throws {
        let http = RecordingHTTP(status: 400, data: Data(#"{"error":"invalid_grant","error_description":"private-access-token"}"#.utf8))
        let client = ClaudeOAuthClient(configuration: ClaudeOAuthConfiguration(clientID: "caller-client"), http: http)
        do {
            _ = try await client.refresh(ClaudeCredentials(accessToken: "access", refreshToken: "refresh", expiresAt: .distantPast))
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertEqual(error as? ClaudeOAuthError, .httpStatus(400))
            XCTAssertFalse(String(reflecting: error).contains("private-access-token"))
        }
    }

    func testProfileIdentityDoesNotRequireAnEmail() throws {
        let profile = try ClaudeProfile.decode(Data(#"{"account":{"uuid":"00000000-0000-0000-0000-000000000001"},"organization":{"uuid":"00000000-0000-0000-0000-000000000002"}}"#.utf8))
        XCTAssertEqual(profile.identity, "00000000-0000-0000-0000-000000000002:00000000-0000-0000-0000-000000000001")
        XCTAssertNil(profile.email)
    }
}

private actor RecordingHTTP: UsageHTTPClient {
    let status: Int
    let data: Data
    private var captured: URLRequest?

    init(status: Int, data: Data) { self.status = status; self.data = data }
    func request() -> URLRequest? { captured }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured = request
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
