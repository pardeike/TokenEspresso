import Foundation
import TokenEspresso

public final class EphemeralUsageHTTPClient: NSObject, UsageHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageHTTPError.invalidResponse("Invalid or oversized HTTP response.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 131_072 else { throw UsageHTTPError.invalidResponse("Invalid or oversized HTTP response.") }
            data.append(byte)
        }
        return (data, response)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
