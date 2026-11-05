import Foundation

@testable import CNCT

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A WebSocket that never touches a network.
///
/// ``sent`` is every frame the client wrote, in order; ``push(_:)`` delivers one to it;
/// ``serverClose(_:)`` ends the connection with a code, which is how the 1008 path gets tested
/// without a server that refuses a token.
final class FakeSocket: CnctSocket, @unchecked Sendable {
  let events: AsyncStream<CnctSocketEvent>
  private let continuation: AsyncStream<CnctSocketEvent>.Continuation
  private let lock = NSLock()
  private var written: [String] = []
  private var closedWith: Int?

  init() {
    (events, continuation) = AsyncStream.makeStream(of: CnctSocketEvent.self)
  }

  /// Every frame the client wrote, in order, as text.
  var sent: [String] {
    lock.lock()
    defer { lock.unlock() }
    return written
  }

  /// Every frame the client wrote, decoded.
  var frames: [CnctJSON] {
    sent.map { (try? JSONDecoder().decode(CnctJSON.self, from: Data($0.utf8))) ?? .null }
  }

  func clearSent() {
    lock.lock()
    defer { lock.unlock() }
    written = []
  }

  /// The code the client closed this with, if it did.
  var closedByClient: Int? {
    lock.lock()
    defer { lock.unlock() }
    return closedWith
  }

  func push(_ text: String) { continuation.yield(.message(text)) }

  func push(_ frame: CnctJSON) {
    push(String(decoding: try! JSONEncoder().encode(frame), as: UTF8.self))
  }

  func serverClose(_ code: Int = 1000) {
    continuation.yield(.closed(code: code))
    continuation.finish()
  }

  func send(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    written.append(text)
  }

  func close(code: Int, reason: String?) {
    lock.lock()
    closedWith = code
    lock.unlock()
    continuation.finish()
  }
}

/// Makes a fresh ``FakeSocket`` for every connect, and remembers them, so a test can drive the
/// socket a reconnect opened as well as the first.
final class FakeSocketFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var made: [FakeSocket] = []
  private var upgrades: [URLRequest] = []

  var make: CnctSocketFactory {
    { [self] request in
      let socket = FakeSocket()
      lock.lock()
      made.append(socket)
      upgrades.append(request)
      lock.unlock()
      return socket
    }
  }

  var sockets: [FakeSocket] {
    lock.lock()
    defer { lock.unlock() }
    return made
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return upgrades
  }

  /// The socket the client most recently opened.
  var last: FakeSocket { sockets.last! }
}

/// Everything a stream yields, from the moment this is made — a chat client's events, or a socket's.
final class EventLog<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [Element] = []
  private var finished = false
  private var task: Task<Void, Never>?

  init(_ stream: AsyncStream<Element>) {
    task = Task { [weak self] in
      for await element in stream { self?.append(element) }
      self?.finish()
    }
  }

  deinit { task?.cancel() }

  private func append(_ element: Element) {
    lock.lock()
    defer { lock.unlock() }
    seen.append(element)
  }

  private func finish() {
    lock.lock()
    defer { lock.unlock() }
    finished = true
  }

  var events: [Element] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }

  /// True once the stream has ended.
  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  func count(where matches: (Element) -> Bool) -> Int { events.filter(matches).count }
}

/// Wait for something asynchronous to become true — the Dart suite's `pumpEventQueue()`, for a
/// client whose work runs on tasks rather than one event loop. False if it never did.
func eventually(within seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if await condition() { return true }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  return await condition()
}
