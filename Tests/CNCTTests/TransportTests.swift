import Foundation
import Testing

@testable import CNCT

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Answers every request from a handler instead of the network. One handler at a time, which is why
/// the suite below is serialized.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  struct Captured: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?

    /// Header names arrive in whatever case URLSession chose, so look them up without caring.
    func header(_ name: String) -> String? {
      headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
  }

  typealias Handler = @Sendable (Captured) throws -> (Int, Data)

  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: Handler?
  nonisolated(unsafe) private static var captured: [Captured] = []

  static func answer(_ handler: @escaping Handler) {
    lock.lock()
    defer { lock.unlock() }
    self.handler = handler
    captured = []
  }

  static var requests: [Captured] {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let body = request.httpBody ?? request.httpBodyStream.map(Self.drain)
    let seen = Captured(
      url: request.url!,
      method: request.httpMethod ?? "GET",
      headers: request.allHTTPHeaderFields ?? [:],
      body: body
    )
    Self.lock.lock()
    Self.captured.append(seen)
    let handler = Self.handler
    Self.lock.unlock()

    do {
      guard let handler else { throw URLError(.unsupportedURL) }
      let (status, data) = try handler(seen)
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  private static func drain(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}

private func transport(_ config: CnctConfig = CnctConfig()) -> CnctTransport {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubProtocol.self]
  return CnctTransport(config: config, session: URLSession(configuration: configuration))
}

private func json(_ text: String) -> Data { Data(text.utf8) }

private func caught(_ body: () async throws -> Void) async -> CnctError? {
  do {
    try await body()
    return nil
  } catch let error as CnctError {
    return error
  } catch {
    Issue.record("expected a CnctError, got \(error)")
    return nil
  }
}

@Suite("CnctTransport", .serialized)
struct TransportTests {
  @Test("sends the SDK's headers and the caller's, and decodes JSON")
  func headersAndJSON() async throws {
    StubProtocol.answer { _ in (200, json(#"{"ok":true,"n":2,"items":["a"]}"#)) }
    var config = CnctConfig()
    config.headers = ["x-trace": "t-1"]
    let answer = try await transport(config).get("/api/x", headers: ["authorization": "Bearer kaer_sk_x"])

    #expect(answer["ok"]?.boolValue == true)
    #expect(answer["n"]?.intValue == 2)
    #expect(answer["items"]?[0]?.stringValue == "a")
    let seen = try #require(StubProtocol.requests.first)
    #expect(seen.url.absoluteString == "https://app.doo.ooo/api/x")
    #expect(seen.header("accept") == "application/json")
    #expect(seen.header("user-agent") == "cnct-ios-sdk/\(CnctConfig.sdkVersion)")
    #expect(seen.header("x-trace") == "t-1")
    #expect(seen.header("authorization") == "Bearer kaer_sk_x")
  }

  @Test("posts a JSON body")
  func postsBody() async throws {
    StubProtocol.answer { _ in (201, json(#"{"id":"m1"}"#)) }
    let answer = try await transport().post("/api/x", body: ["text": "hello", "n": 1])
    #expect(answer["id"]?.stringValue == "m1")
    let seen = try #require(StubProtocol.requests.first)
    #expect(seen.method == "POST")
    #expect(seen.header("content-type") == "application/json")
    let sent = try JSONDecoder().decode(CnctJSON.self, from: try #require(seen.body))
    #expect(sent == ["text": "hello", "n": 1])
  }

  @Test("answers null for a 204 or an empty body")
  func empty() async throws {
    StubProtocol.answer { _ in (204, Data()) }
    #expect(try await transport().delete("/api/x") == .null)
  }

  @Test("maps statuses to codes", arguments: [
    (400, CnctErrorCode.invalid), (401, .unauthenticated), (403, .unauthenticated), (404, .notFound),
    (409, .conflict), (413, .tooLarge), (429, .rateLimited), (500, .serverError), (503, .serverError),
    (418, .requestFailed),
  ])
  func statusCodes(status: Int, expected: CnctErrorCode) async {
    StubProtocol.answer { _ in (status, json(#"{"error":"nope"}"#)) }
    let error = await caught { _ = try await transport().get("/api/x") }
    #expect(error?.code == expected)
    #expect(error?.status == status)
    #expect(error?.message == "nope")
    #expect(error?.details?["error"]?.stringValue == "nope")
  }

  @Test("the server's own code wins over the status")
  func serverCodeWins() async {
    StubProtocol.answer { _ in (409, json(#"{"error":"closed","code":"conversation_closed"}"#)) }
    let error = await caught { _ = try await transport().post("/api/x") }
    #expect(error?.code == .conversationClosed)
  }

  @Test("a validation refusal keeps the fields and says it was refused")
  func validationRefusal() async {
    StubProtocol.answer { _ in (400, json(#"{"error":{"fieldErrors":{"phone":["bad"]},"formErrors":[]}}"#)) }
    let error = await caught { _ = try await transport().post("/api/x") }
    #expect(error?.code == .invalid)
    #expect(error?.message == "That request was refused.")
    #expect(error?.details?["error"]?["fieldErrors"]?["phone"]?[0]?.stringValue == "bad")
  }

  @Test("problem+json title becomes the message")
  func problemJSON() async {
    StubProtocol.answer { _ in (429, json(#"{"title":"Slow down","code":"rate_limited"}"#)) }
    let error = await caught { _ = try await transport().get("/api/x") }
    #expect(error?.message == "Slow down")
    #expect(error?.code == .rateLimited)
    #expect(error?.isRetryable == true)
  }

  @Test("a 200 that is not JSON is a bad response, pointing at the base URL")
  func notJSON() async {
    StubProtocol.answer { _ in (200, json("<html>login</html>")) }
    let error = await caught { _ = try await transport().get("/api/x") }
    #expect(error?.code == .badResponse)
  }

  @Test("an error that is not JSON keeps the raw body as the message")
  func errorNotJSON() async {
    StubProtocol.answer { _ in (502, json("Bad gateway")) }
    let error = await caught { _ = try await transport().get("/api/x") }
    #expect(error?.code == .serverError)
    #expect(error?.message == "Bad gateway")
  }

  @Test("no network is offline and retryable, not a refusal")
  func offline() async {
    StubProtocol.answer { _ in throw URLError(.notConnectedToInternet) }
    let error = await caught { _ = try await transport().get("/api/x") }
    #expect(error?.code == .offline)
    #expect(error?.isRetryable == true)
  }

  @Test("a timeout is a timeout")
  func timeout() async {
    StubProtocol.answer { _ in throw URLError(.timedOut) }
    let error = await caught { _ = try await transport().get("/api/x") }
    #expect(error?.code == .timeout)
  }

  @Test("downloads bytes with the same error mapping")
  func bytes() async throws {
    StubProtocol.answer { _ in (200, Data([1, 2, 3])) }
    #expect(try await transport().bytes("/api/file") == Data([1, 2, 3]))
    StubProtocol.answer { _ in (401, json(#"{"error":"expired"}"#)) }
    let error = await caught { _ = try await transport().bytes("/api/file") }
    #expect(error?.isUnauthenticated == true)
  }
}
