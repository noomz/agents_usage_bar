import Testing
import Foundation
@testable import AgentsUsageBar

// MARK: - URLProtocol Stub

/// Thread-safe stub for URLProtocol interception.
/// Uses OSAllocatedUnfairLock to protect the shared closure from concurrent test execution.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub: ((URLRequest) -> (Data, HTTPURLResponse))? = nil

    static var stub: ((URLRequest) -> (Data, HTTPURLResponse))? {
        get { lock.withLock { _stub } }
        set { lock.withLock { _stub = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = StubURLProtocol.stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (data, response) = stub(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Test helpers

private func makeStubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

private func makeResponse(status: Int, url: URL = URL(string: "https://openrouter.ai/api/v1/credits")!) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

// MARK: - Test payload

private struct CreditsPayload: Decodable, Sendable {
    struct Data: Decodable {
        let totalCredits: Double
        let totalUsage: Double
    }
    let data: Data
}

// MARK: - Tests

// Serialized to prevent StubURLProtocol.stub races when Swift Testing runs tests in parallel.
@Suite("URLSessionHTTPClientTests", .serialized)
struct URLSessionHTTPClientTests {

    private let testURL = URL(string: "https://openrouter.ai/api/v1/credits")!

    @Test("get 200 decodes payload")
    func get_200_decodesPayload() async throws {
        let json = """
        {"data":{"total_credits":100.5,"total_usage":25.3}}
        """.data(using: .utf8)!
        StubURLProtocol.stub = { _ in (json, makeResponse(status: 200)) }
        let client = URLSessionHTTPClient(session: makeStubSession())
        let result = try await client.get(testURL, bearer: Secret("test-key"), extraHeaders: [:], as: CreditsPayload.self)
        #expect(abs(result.data.totalCredits - 100.5) < 0.001)
        #expect(abs(result.data.totalUsage - 25.3) < 0.001)
    }

    @Test("get 401 throws HTTPError")
    func get_401_throwsHTTPError() async throws {
        StubURLProtocol.stub = { _ in (Data(), makeResponse(status: 401)) }
        let client = URLSessionHTTPClient(session: makeStubSession())
        await #expect(throws: HTTPError.self) {
            _ = try await client.get(testURL, bearer: Secret("test-key"), extraHeaders: [:], as: CreditsPayload.self)
        }
    }

    @Test("get 500 throws HTTPError")
    func get_500_throwsHTTPError() async throws {
        StubURLProtocol.stub = { _ in (Data(), makeResponse(status: 500)) }
        let client = URLSessionHTTPClient(session: makeStubSession())
        await #expect(throws: HTTPError.self) {
            _ = try await client.get(testURL, bearer: Secret("test-key"), extraHeaders: [:], as: CreditsPayload.self)
        }
    }

    @Test("get sets Authorization header with bearer token")
    func get_setsAuthorizationHeader() async throws {
        let json = """
        {"data":{"total_credits":1.0,"total_usage":0.0}}
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        StubURLProtocol.stub = { req in
            capturedRequest = req
            return (json, makeResponse(status: 200))
        }
        let client = URLSessionHTTPClient(session: makeStubSession())
        _ = try await client.get(testURL, bearer: Secret("test-key"), extraHeaders: [:], as: CreditsPayload.self)
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test("get sets extra headers")
    func get_setsExtraHeaders() async throws {
        let json = """
        {"data":{"total_credits":1.0,"total_usage":0.0}}
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        StubURLProtocol.stub = { req in
            capturedRequest = req
            return (json, makeResponse(status: 200))
        }
        let client = URLSessionHTTPClient(session: makeStubSession())
        _ = try await client.get(testURL, bearer: Secret("test-key"), extraHeaders: ["X-Title": "MyApp"], as: CreditsPayload.self)
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-Title") == "MyApp")
    }

    @Test("URLSession timeout configured to 8 seconds")
    func urlSessionTimeoutConfigured() {
        let client = URLSessionHTTPClient()
        #expect(client.configurationSnapshot().timeoutIntervalForRequest == 8)
    }

    @Test("URLSession waitsForConnectivity is false")
    func urlSessionWaitsForConnectivityFalse() {
        let client = URLSessionHTTPClient()
        #expect(client.configurationSnapshot().waitsForConnectivity == false)
    }

    @Test("URLSession connections per host equals 6")
    func urlSessionConnectionsPerHostEqualsSix() {
        let client = URLSessionHTTPClient()
        #expect(client.configurationSnapshot().httpMaximumConnectionsPerHost == 6)
    }
}
