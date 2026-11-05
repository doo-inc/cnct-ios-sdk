import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// What the server said on the chat socket, or that it stopped.
public enum CnctSocketEvent: Sendable, Hashable {
  /// A frame. Binary frames arrive here too, read as UTF-8.
  case message(String)

  /// The connection ended. `code` is the close code the server sent, where it sent one — `1008`
  /// means the session token did not resolve.
  case closed(code: Int?)
}

/// A WebSocket, as far as the chat client needs one.
///
/// Behind a protocol so a test can drive the chat client with a fake socket and no server — the
/// Flutter SDK's `CnctSocketFactory`, made a type. ``CnctURLSessionSocket`` is the real one.
public protocol CnctSocket: Sendable {
  /// Everything the server says, in order, ending with one ``CnctSocketEvent/closed(code:)``.
  /// Iterated once, by the client that opened it.
  var events: AsyncStream<CnctSocketEvent> { get }

  /// Write a text frame. Fire and forget: a frame lost to a dying connection is what the send
  /// timeout and the reconnect-and-reload are for.
  func send(_ text: String)

  /// Close from this side. No ``CnctSocketEvent/closed(code:)`` is owed after this — the client has
  /// already stopped listening.
  func close(code: Int, reason: String?)
}

/// How a chat socket gets made. Given the upgrade request — the URL under ``CnctConfig/socketBaseURL``
/// plus the configured headers and user agent — and nothing else: the session token travels in the
/// first frame, never in the URL, where it would end up in a proxy's access log.
public typealias CnctSocketFactory = @Sendable (URLRequest) throws -> any CnctSocket

/// The chat socket on `URLSessionWebSocketTask`.
///
/// Each socket gets its own `URLSession`, because the close code a server sends — the difference
/// between "reconnect" and "this token is dead" — only reliably reaches a session delegate.
public final class CnctURLSessionSocket: CnctSocket, @unchecked Sendable {
  public let events: AsyncStream<CnctSocketEvent>

  private let ending: Ending
  private let session: URLSession
  private let task: URLSessionWebSocketTask

  /// Opens the connection straight away.
  public init(request: URLRequest, configuration: URLSessionConfiguration = .default) {
    let (events, continuation) = AsyncStream.makeStream(of: CnctSocketEvent.self)
    let ending = Ending(continuation)
    self.events = events
    self.ending = ending
    self.session = URLSession(configuration: configuration, delegate: Delegate(ending), delegateQueue: nil)
    self.task = session.webSocketTask(with: request)
    task.resume()
    Self.receive(task, ending)
  }

  public func send(_ text: String) {
    // An error here is the connection dying, and the receive loop reports that with its close code.
    task.send(.string(text)) { _ in }
  }

  public func close(code: Int, reason: String?) {
    task.cancel(
      with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure,
      reason: reason.map { Data($0.utf8) }
    )
    session.finishTasksAndInvalidate()
    ending.finish(code: code)
  }

  private static func receive(_ task: URLSessionWebSocketTask, _ ending: Ending) {
    task.receive { result in
      switch result {
      case .success(.string(let text)):
        ending.yield(.message(text))
        receive(task, ending)
      case .success(.data(let data)):
        ending.yield(.message(String(decoding: data, as: UTF8.self)))
        receive(task, ending)
      case .success:
        receive(task, ending)
      case .failure:
        // The close code is only worth reporting once it is known. When it is not known yet, the
        // delegate's close or completion callback — one of which always follows — finishes this.
        if task.closeCode != .invalid { ending.finish(code: task.closeCode.rawValue) }
      }
    }
  }

  /// Finishes the event stream exactly once, whichever of the receive loop, the delegate and
  /// `close` gets there first.
  final class Ending: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<CnctSocketEvent>.Continuation
    private var finished = false

    init(_ continuation: AsyncStream<CnctSocketEvent>.Continuation) {
      self.continuation = continuation
    }

    func yield(_ event: CnctSocketEvent) {
      lock.lock()
      defer { lock.unlock() }
      if !finished { continuation.yield(event) }
    }

    func finish(code: Int?) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      finished = true
      continuation.yield(.closed(code: code))
      lock.unlock()
      continuation.finish()
    }
  }

  private final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let ending: Ending

    init(_ ending: Ending) {
      self.ending = ending
    }

    // Nothing to do: the client authenticates by writing its first frame, which URLSession queues
    // until the connection is open. Implemented because Linux's Foundation requires it.
    func urlSession(
      _ session: URLSession,
      webSocketTask: URLSessionWebSocketTask,
      didOpenWithProtocol protocol: String?
    ) {}

    func urlSession(
      _ session: URLSession,
      webSocketTask: URLSessionWebSocketTask,
      didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
      reason: Data?
    ) {
      ending.finish(code: closeCode.rawValue)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      let code = (task as? URLSessionWebSocketTask)?.closeCode
      ending.finish(code: code == nil || code == .invalid ? nil : code!.rawValue)
      // The session holds its delegate until it is invalidated; this is the last callback it makes.
      session.finishTasksAndInvalidate()
    }
  }
}

/// Hands every value to every listener, each on an `AsyncStream` of its own.
///
/// What a Dart broadcast `StreamController` is to the Flutter SDK. Registration happens under the
/// lock on the caller's thread, so a listener that subscribes before calling `start()` cannot miss
/// what `start()` causes.
final class CnctBroadcast<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var listeners: [Int: AsyncStream<Element>.Continuation] = [:]
  private var nextListener = 0
  private var finished = false
  private var current: Element?
  private let replays: Bool

  /// A broadcast that hands a new listener the latest value first — for state, where a listener
  /// that subscribes between two changes still needs to know where things are.
  init(replaying initial: Element) {
    current = initial
    replays = true
  }

  /// A broadcast that hands a new listener only what happens next — for events.
  init() {
    replays = false
  }

  /// The latest value, for a broadcast that replays.
  var latest: Element? {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func stream() -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
    lock.lock()
    if finished {
      lock.unlock()
      continuation.finish()
      return stream
    }
    let id = nextListener
    nextListener += 1
    listeners[id] = continuation
    if replays, let current { continuation.yield(current) }
    lock.unlock()
    continuation.onTermination = { [weak self] _ in self?.remove(id) }
    return stream
  }

  func yield(_ value: Element) {
    // Yielding under the lock keeps every listener's order identical to the order of the calls.
    // `yield` never calls back into `onTermination`, so this cannot deadlock.
    lock.lock()
    defer { lock.unlock() }
    if replays { current = value }
    for listener in listeners.values { listener.yield(value) }
  }

  func finish() {
    lock.lock()
    finished = true
    let ending = listeners.values
    listeners = [:]
    lock.unlock()
    for listener in ending { listener.finish() }
  }

  private func remove(_ id: Int) {
    lock.lock()
    defer { lock.unlock() }
    listeners[id] = nil
  }
}
