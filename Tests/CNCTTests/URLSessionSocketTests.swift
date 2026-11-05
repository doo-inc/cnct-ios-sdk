#if canImport(Network)
  import Foundation
  @preconcurrency import Network
  import Testing

  @testable import CNCT

  /// A real WebSocket server on the loopback interface.
  ///
  /// Everything else in the chat suite runs on a fake socket, which proves the client and proves
  /// nothing about `URLSessionWebSocketTask`. These tests are the ones that do: real frames over a
  /// real connection, and — the part a fake cannot show — the server's close code actually reaching
  /// the client, because 1008 is the difference between "reconnect" and "this token is dead".
  ///
  /// It answers the way the platform's visitor socket does, as far as these tests need: `auth` with
  /// the token `good` is `authenticated` (with socket sends offered), any other token is a 1008 close,
  /// and a `send` is acknowledged with the stored row.
  final class LoopbackSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cnct.tests.loopback")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init() throws {
      let parameters = NWParameters.tcp
      parameters.requiredInterfaceType = .loopback
      let websocket = NWProtocolWebSocket.Options()
      websocket.autoReplyPing = true
      parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
      listener = try NWListener(using: parameters, on: .any)
    }

    /// Start listening, and answer the port.
    func start() async throws -> UInt16 {
      listener.newConnectionHandler = { [self] connection in
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(on: connection)
      }
      return try await withCheckedThrowingContinuation { continuation in
        let once = Once()
        listener.stateUpdateHandler = { [listener] state in
          switch state {
          case .ready:
            if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
          case .failed(let error):
            if once.claim() { continuation.resume(throwing: error) }
          default:
            break
          }
        }
        listener.start(queue: queue)
      }
    }

    func stop() {
      listener.cancel()
      lock.lock()
      let open = connections
      connections = []
      lock.unlock()
      for connection in open { connection.cancel() }
    }

    private func receive(on connection: NWConnection) {
      connection.receiveMessage { [self] data, context, _, error in
        if error != nil { return }
        let metadata =
          context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        if let data, metadata?.opcode == .text {
          answer(String(decoding: data, as: UTF8.self), on: connection)
        }
        receive(on: connection)
      }
    }

    private func answer(_ text: String, on connection: NWConnection) {
      guard let frame = try? JSONDecoder().decode(CnctJSON.self, from: Data(text.utf8)) else { return }
      switch frame["type"]?.stringValue {
      case "auth":
        if frame["token"]?.stringValue == "good" {
          send(["type": "authenticated", "accepts": ["ping", "typing", "send"]], on: connection)
        } else {
          close(connection, .protocolCode(.policyViolation))
        }
      case "send":
        send(
          [
            "type": "ack",
            "id": frame["id"] ?? .null,
            "message": [
              "id": "msg_real", "speaker": "CALLER", "type": "TEXT", "body": frame["body"] ?? "",
              "createdAt": "2026-09-08T10:00:00.000Z", "clientKey": frame["clientKey"] ?? .null,
            ],
          ],
          on: connection
        )
      default:
        return
      }
    }

    private func send(_ frame: CnctJSON, on connection: NWConnection) {
      let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
      let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
      let data = (try? JSONEncoder().encode(frame)) ?? Data()
      connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func close(_ connection: NWConnection, _ code: NWProtocolWebSocket.CloseCode) {
      let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
      metadata.closeCode = code
      let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
      connection.send(content: nil, contentContext: context, isComplete: true, completion: .idempotent)
    }
  }

  /// True the first time it is asked, and never again.
  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if claimed { return false }
      claimed = true
      return true
    }
  }

  @Suite("CnctURLSessionSocket, on a real connection")
  struct URLSessionSocketTests {
    @Test("frames go both ways, and closing from this side ends the stream")
    func framesBothWays() async throws {
      let server = try LoopbackSocketServer()
      let port = try await server.start()
      defer { server.stop() }

      let socket = CnctURLSessionSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws/chat")!))
      let log = EventLog(socket.events)
      socket.send(#"{"type":"auth","token":"good"}"#)

      #expect(await eventually { !log.events.isEmpty })
      guard case .message(let text) = log.events.first else {
        Issue.record("expected a frame first, got \(log.events)")
        return
      }
      let frame = try JSONDecoder().decode(CnctJSON.self, from: Data(text.utf8))
      #expect(frame["type"]?.stringValue == "authenticated")

      socket.close(code: 1000, reason: "done")
      #expect(await eventually { log.isFinished })
      #expect(log.events.last == .closed(code: 1000))
    }

    @Test("the server's 1008 reaches the client as 1008")
    func closeCodeArrives() async throws {
      let server = try LoopbackSocketServer()
      let port = try await server.start()
      defer { server.stop() }

      let socket = CnctURLSessionSocket(request: URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/ws/chat")!))
      let log = EventLog(socket.events)
      socket.send(#"{"type":"auth","token":"expired"}"#)

      #expect(await eventually { log.isFinished })
      #expect(log.events.last == .closed(code: 1008))
    }

    @Test("the chat client goes live and sends over a real socket, and a dead token ends the session")
    func clientOnARealSocket() async throws {
      let server = try LoopbackSocketServer()
      let port = try await server.start()
      defer { server.stop() }

      // HTTP still goes to the fake host; only the socket is real, pointed at the loopback server.
      let token = Locked("good")
      let http = FakeServer { request in
        switch request.url.path {
        case "/api/chat/public/inbox-key/session":
          return (
            200,
            [
              "token": .string(token.get),
              "conversation": ["status": "OPEN", "startedAt": "2026-09-08T09:59:00.000Z"],
              "messages": [],
            ]
          )
        case "/api/chat/public/session":
          return (200, ["conversation": ["status": "OPEN", "startedAt": "2026-09-08T09:59:00.000Z"], "messages": []])
        default:
          return (404, ["error": "not found"])
        }
      }
      let store = CnctMemoryTokenStore()
      let chat = CnctChatClient(
        config: http.config,
        credentials: try CnctChatPublicKey("inbox-key"),
        tokenStore: store,
        transport: http.transport(),
        socketFactory: { request in
          var loopback = request
          loopback.url = URL(string: "ws://127.0.0.1:\(port)/ws/chat")
          return CnctURLSessionSocket(request: loopback)
        }
      )
      let events = EventLog(chat.events)

      try await chat.start(displayName: "Layla")
      #expect(await eventually { events.count { $0 == .connected } == 1 })
      #expect(chat.state.status == .live)

      let stored = try await chat.send("Over a real socket")
      #expect(stored.id == "msg_real")
      #expect(!http.paths.contains("/api/chat/public/messages"))

      // A token the socket refuses: the server closes with 1008 and the session is forgotten.
      await chat.dispose()
      token.set("expired")
      let refused = CnctChatClient(
        config: http.config,
        credentials: try CnctChatPublicKey("inbox-key"),
        tokenStore: store,
        transport: http.transport(),
        socketFactory: { request in
          var loopback = request
          loopback.url = URL(string: "ws://127.0.0.1:\(port)/ws/chat")
          return CnctURLSessionSocket(request: loopback)
        }
      )
      let refusedEvents = EventLog(refused.events)
      try await refused.start(displayName: "Layla")
      #expect(await eventually { refusedEvents.count { $0 == .unauthenticated } == 1 })
      #expect(await !refused.hasSession)
      #expect(try await store.read("cnct_chat_inbox-key") == nil)
      await refused.dispose()
    }
  }
#endif
