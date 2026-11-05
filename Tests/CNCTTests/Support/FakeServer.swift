import Foundation
import Testing

@testable import CNCT

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A CNCT host that answers from a closure instead of a network.
///
/// Every server gets a host name of its own and requests are routed by it, so suites built on this
/// run in parallel with each other — unlike ``StubProtocol``, whose one global handler is why the
/// transport suite has to be serialized.
final class FakeServer: @unchecked Sendable {
  typealias Request = StubProtocol.Captured
  typealias Handler = @Sendable (Request) throws -> (Int, CnctJSON)

  let host: String
  let config: CnctConfig

  private let lock = NSLock()
  private var handler: Handler
  private var seen: [Request] = []

  init(_ handler: @escaping Handler) {
    host = "s\(UUID().uuidString.lowercased()).cnct.test"
    config = try! CnctConfig(baseURL: "https://\(host)")
    self.handler = handler
    RoutedProtocol.register(self)
  }

  /// Every request this server has answered, in order.
  var requests: [Request] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }

  /// The paths requested, in order.
  var paths: [String] { requests.map(\.url.path) }

  func clearRequests() {
    lock.lock()
    defer { lock.unlock() }
    seen = []
  }

  /// A transport whose every request lands here.
  func transport() -> CnctTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutedProtocol.self]
    return CnctTransport(config: config, session: URLSession(configuration: configuration))
  }

  fileprivate func handle(_ request: Request) throws -> (Int, Data) {
    lock.lock()
    seen.append(request)
    let handler = self.handler
    lock.unlock()
    let (status, body) = try handler(request)
    return (status, try JSONEncoder().encode(body))
  }
}

extension StubProtocol.Captured {
  /// The JSON body this request carried, or null.
  var json: CnctJSON {
    guard let body, !body.isEmpty else { return .null }
    return (try? JSONDecoder().decode(CnctJSON.self, from: body)) ?? .null
  }
}

/// Sends each request to the ``FakeServer`` that owns its host.
final class RoutedProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var servers: [String: FakeServer] = [:]

  static func register(_ server: FakeServer) {
    lock.lock()
    defer { lock.unlock() }
    servers[server.host] = server
  }

  private static func server(for host: String?) -> FakeServer? {
    lock.lock()
    defer { lock.unlock() }
    return host.flatMap { servers[$0] }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let body = request.httpBody ?? request.httpBodyStream.map(Self.drain)
    let seen = StubProtocol.Captured(
      url: request.url!,
      method: request.httpMethod ?? "GET",
      headers: request.allHTTPHeaderFields ?? [:],
      body: body
    )
    do {
      guard let server = Self.server(for: request.url?.host) else { throw URLError(.cannotFindHost) }
      let (status, data) = try server.handle(seen)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["content-type": "application/json"])!
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

/// The error a call threw, or nil — recording an issue when it threw something that is not a
/// ``CnctError``.
func caughtCnctError(_ body: () async throws -> Void) async -> CnctError? {
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
