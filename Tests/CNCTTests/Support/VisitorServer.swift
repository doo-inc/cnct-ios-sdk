import Foundation
import Testing

@testable import CNCT

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

let visitorKey = "inbox-public-key"

/// A conversation as the server sends one, with an id — the shape the 1.0 visitor API speaks.
func conversationJson(
  id: String = "conv_1",
  status: String = "OPEN",
  ratable: Bool = false,
  rating: CnctJSON = .null,
  seenAt: CnctJSON = .null
) -> CnctJSON {
  [
    "id": .string(id),
    "status": .string(status),
    "startedAt": "2026-09-08T09:59:00.000Z",
    "closedAt": status == "CLOSED" ? "2026-09-08T10:30:00.000Z" : .null,
    "withPerson": true,
    "assignee": ["kind": "person", "name": "Sara", "avatar": "fox-clay"],
    "seenAt": seenAt,
    "ratable": .bool(ratable),
    "rating": rating,
  ]
}

/// The platform's visitor API, as far as the 1.0 tests need it: every route answers from a closure
/// a test can swap, so each test says only what it changes.
final class VisitorServer: @unchecked Sendable {
  typealias Route = @Sendable (FakeServer.Request) -> (Int, CnctJSON)

  private let lock = NSLock()
  private var routes: [String: Route] = [:]
  var transcript: [CnctJSON] = [messageJson(id: "msg_0", speaker: "SYSTEM", body: "Hello. How can we help?")]
  lazy var server = FakeServer { [unowned self] request in self.answer(request) }

  init() {}

  func on(_ method: String, _ path: String, _ route: @escaping Route) {
    lock.lock()
    defer { lock.unlock() }
    routes["\(method) \(path)"] = route
  }

  func requests(_ method: String, _ path: String) -> [FakeServer.Request] {
    server.requests.filter { $0.method == method && $0.url.path == path }
  }

  private func answer(_ request: FakeServer.Request) -> (Int, CnctJSON) {
    lock.lock()
    let route = routes["\(request.method) \(request.url.path)"]
    let transcript = self.transcript
    lock.unlock()
    if let route { return route(request) }
    switch (request.method, request.url.path) {
    case ("GET", "/api/chat/public/\(visitorKey)"):
      return (200, ["business": "Demo Café", "inbox": "App", "isActive": true, "greeting": "Hello.", "requirePhone": false])
    case ("POST", "/api/chat/public/\(visitorKey)/session"):
      return (
        200,
        [
          "token": "visitor-token-1",
          "visitor": ["displayName": "Layla", "anonymous": false, "identified": false],
          "conversation": conversationJson(),
          "messages": .array(transcript),
        ]
      )
    case ("GET", "/api/chat/public/session"):
      return (200, ["visitor": ["displayName": "Layla"], "conversation": conversationJson(), "messages": .array(transcript)])
    case ("POST", "/api/chat/public/messages"):
      return (
        200,
        messageJson(
          id: "msg_stored", speaker: "CALLER", body: request.json["body"]?.stringValue ?? "",
          clientKey: request.json["clientKey"]?.stringValue)
      )
    case ("POST", "/api/chat/public/close"):
      return (200, ["ok": true])
    default:
      return (404, ["error": "not found"])
    }
  }

  func client(
    store: (any CnctTokenStore)? = nil,
    sockets: FakeSocketFactory = FakeSocketFactory()
  ) -> CnctChatClient {
    CnctChatClient(
      config: server.config,
      credentials: try! CnctChatPublicKey(visitorKey),
      tokenStore: store ?? CnctMemoryTokenStore(),
      transport: server.transport(),
      socketFactory: sockets.make
    )
  }
}

/// A 64 × 48 landscape photo in HEIC, as an iPhone takes them — the format the platform refuses.
let tinyHEIC = Data(base64Encoded: "AAAAHGZ0eXBoZWljAAAAAG1pZjFoZWljbWlhZgAAAX1tZXRhAAAAAAAAACFoZGxyAAAAAAAAAABwaWN0AAAAAAAAAAAAAAAAAAAAACJpbG9jAAAAAERAAAEAAQAAAAABoQABAAAAAAAAAPcAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAA5waXRtAAAAAAABAAAA/WlwcnAAAADdaXBjbwAAAHZodmNDAQNwAAAAkAAAAAAAHvAA/P34+AAADwNgAAEAGEABDAH//wNwAAADAJAAAAMAAAMAHroCQGEAAQAqQgEBA3AAAAMAkAAAAwAAAwAeoCCBBZbq5Ka5uAhoMCAAAAMDIAAAAwAhYgABAAZEAcFzwIkAAAATY29scm5jbHgAAQANAAaAAAAAFGlzcGUAAAAAAAAAQAAAAEAAAAAoY2xhcAAAAEAAAAABAAAAMAAAAAEAAAAAAAAAAv////AAAAACAAAAEHBpeGkAAAAAAwgICAAAABhpcG1hAAAAAAAAAAEAAQWBAgMFhAAAAP9tZGF0AAAA8ygBrwngd0HDXE//j3+99R///Y9PXKQJYZO0/gtgmN+GKptZ9D5bwEVbBM9j9oVLz0HBHsuAu+SnlhNM0gVHxMB2ZD5VVsUH5cHOhuFNHpZgG0w4R3VgSt0GZCBc19akbv0hZPWoTGrvV2ZeBXT7wHB4heC2Vz+vBSL7X17dEpmUuLkEjOdBdClixho+Rf77HAlet7lZJes31NoGQMMotwrCc9x7PV0uhXMJtIVJy5uMBJSLoqndF6JaiMisEew0+lL8ZrhZRG4LsmidulfsNjl3Li0vtm7+klclYWD59byM5raQdT9VmaGhN551cAAhm7WZwA==")!
