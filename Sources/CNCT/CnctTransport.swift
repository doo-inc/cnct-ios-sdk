import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// The one place this SDK talks HTTP.
///
/// Every module goes through it, so the error vocabulary, the timeout, the headers and the JSON
/// handling are decided once. A module that built its own request would be a module that maps a
/// 429 to something slightly different, and an integrator branching on ``CnctErrorCode`` would be
/// right about one of them.
public final class CnctTransport: Sendable {
  public let config: CnctConfig
  private let session: URLSession

  /// `session` defaults to `URLSession.shared`. Pass your own for a custom configuration — or, in a
  /// test, one whose `protocolClasses` answers without a network.
  public init(config: CnctConfig, session: URLSession = .shared) {
    self.config = config
    self.session = session
  }

  public func get(_ path: String, query: [String: Any?] = [:], headers: [String: String] = [:]) async throws
    -> CnctJSON
  {
    try await send("GET", path, query: query, headers: headers)
  }

  public func post(
    _ path: String, body: CnctJSON? = nil, query: [String: Any?] = [:], headers: [String: String] = [:]
  ) async throws -> CnctJSON {
    try await send("POST", path, body: body, query: query, headers: headers)
  }

  public func patch(_ path: String, body: CnctJSON? = nil, headers: [String: String] = [:]) async throws
    -> CnctJSON
  {
    try await send("PATCH", path, body: body, headers: headers)
  }

  public func delete(_ path: String, headers: [String: String] = [:]) async throws -> CnctJSON {
    try await send("DELETE", path, headers: headers)
  }

  /// The raw bytes of something — an attachment, an export. Same auth and same error mapping as the
  /// JSON paths, because a 401 on a file download is the same event as a 401 anywhere else.
  public func bytes(_ path: String, headers: [String: String] = [:]) async throws -> Data {
    let request = makeRequest("GET", config.resolve(path), headers: headers)
    let (data, status) = try await run(request)
    if status >= 400 { throw failure(status, data, try? JSONDecoder().decode(CnctJSON.self, from: data)) }
    return data
  }

  /// Post a body that is not JSON — a file, as `multipart/form-data` — and answer the JSON that
  /// comes back, with the same error mapping as everything else.
  ///
  /// `progress` hears how much of the body has gone, from 0 to 1, as the system sends it, and always
  /// hears 1 once the server has answered. It is called from a background queue.
  public func upload(
    _ path: String,
    body: Data,
    contentType: String,
    headers: [String: String] = [:],
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> CnctJSON {
    var request = makeRequest("POST", config.resolve(path), headers: headers)
    request.setValue(contentType, forHTTPHeaderField: "content-type")
    let (data, status) = try await run(request, upload: body, progress: progress)
    config.logger?(.debug, "POST \(path) → \(status)", nil)
    progress?(1)
    return try decode("POST", status, data)
  }

  /// Send a request and answer its JSON. An empty body or a `204` answers ``CnctJSON/null``.
  public func send(
    _ method: String,
    _ path: String,
    body: CnctJSON? = nil,
    query: [String: Any?] = [:],
    headers: [String: String] = [:]
  ) async throws -> CnctJSON {
    var request = makeRequest(method, config.resolve(path, query: query), headers: headers)
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "content-type")
      request.httpBody = try JSONEncoder().encode(body)
    }

    let (data, status) = try await run(request)
    config.logger?(.debug, "\(method) \(path) → \(status)", nil)
    return try decode(method, status, data)
  }

  /// A response's JSON, or the error it carries.
  private func decode(_ method: String, _ status: Int, _ data: Data) throws -> CnctJSON {
    if status == 204 || data.isEmpty {
      if status >= 400 { throw failure(status, data) }
      return .null
    }

    let decoded: CnctJSON
    do {
      decoded = try JSONDecoder().decode(CnctJSON.self, from: data)
    } catch {
      if status >= 400 { throw failure(status, data) }
      throw CnctError(
        "The server answered with something that is not JSON. Check that baseURL points at a CNCT "
          + "host and not at a login page or a proxy error.",
        code: .badResponse,
        status: status
      )
    }

    if status >= 400 { throw failure(status, data, decoded) }
    return decoded
  }

  // MARK: - Private

  private func makeRequest(_ method: String, _ url: URL, headers: [String: String]) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: config.connectTimeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.setValue(config.userAgent, forHTTPHeaderField: "user-agent")
    for (name, value) in config.headers { request.setValue(value, forHTTPHeaderField: name) }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  /// A data task wrapped by hand rather than `session.data(for:)`, so it behaves the same on every
  /// OS this supports and cancels with the calling task.
  private func run(
    _ request: URLRequest,
    upload body: Data? = nil,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> (Data, Int) {
    let box = TaskBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int), any Error>) in
        let finished: @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { data, response, error in
          if let error {
            continuation.resume(throwing: self.mapNetworkError(error))
            return
          }
          guard let http = response as? HTTPURLResponse else {
            continuation.resume(
              throwing: CnctError("The response was not HTTP.", code: .badResponse))
            return
          }
          continuation.resume(returning: (data ?? Data(), http.statusCode))
        }
        let task: URLSessionTask
        if let body {
          // The body travels as the upload task's own, which is what the system streams and reports
          // progress on. It is also left on the request, where URLSession ignores it, for a
          // `URLProtocol` — a test's, a debugging proxy's — that reads the request rather than the
          // task. `Data` is shared, not copied, so this costs nothing.
          var request = request
          request.httpBody = body
          task = session.uploadTask(with: request, from: body, completionHandler: finished)
          // A delegate of the task's own, so progress reaches this upload and nothing else — the
          // session may be `URLSession.shared`, which has no delegate to ask.
          if let progress { task.delegate = UploadProgress(progress) }
        } else {
          task = session.dataTask(with: request, completionHandler: finished)
        }
        box.set(task)
        task.resume()
      }
    } onCancel: {
      box.cancel()
    }
  }

  private func mapNetworkError(_ error: any Error) -> any Error {
    let host = config.baseURL.host ?? config.baseURL.absoluteString
    guard let urlError = error as? URLError else {
      return CnctError("Could not reach \(host): \(error.localizedDescription)", code: .offline)
    }
    switch urlError.code {
    case .timedOut:
      return CnctError("The request timed out after \(Int(config.connectTimeout))s.", code: .timeout)
    case .cancelled:
      return CancellationError()
    default:
      // A dead network, a refused connection, DNS. Distinct from an answer, because a UI should
      // retry one and not the other.
      return CnctError("Could not reach \(host): \(urlError.localizedDescription)", code: .offline)
    }
  }

  /// Turn a failed response into an error with a code worth branching on.
  ///
  /// The platform answers in three shapes and all three are handled here rather than at the call
  /// sites: `{error: "a sentence"}`, `{error: {fieldErrors, formErrors}}` from a validation
  /// refusal, and `application/problem+json` with its own `code`. Where the body names a code, that
  /// code wins — the server is more specific about its own failures than a status line can be.
  private func failure(_ status: Int, _ data: Data, _ decoded: CnctJSON? = nil) -> CnctError {
    let raw = String(decoding: data, as: UTF8.self)
    var message = raw.isEmpty ? "Request failed with \(status)." : raw
    var details: CnctJSON?
    var serverCode: String?

    if let decoded, case .object = decoded {
      // The whole body, always. A refusal often carries more than a sentence, and a transport that
      // keeps only the message throws that away at the one moment it is useful.
      details = decoded
      if let error = decoded["error"] {
        message = error.stringValue ?? (error.isNull ? message : "That request was refused.")
      }
      if let title = decoded["title"]?.stringValue { message = title }
      serverCode = decoded["code"]?.stringValue
    }

    let code: CnctErrorCode
    if let serverCode {
      code = CnctErrorCode(rawValue: serverCode)
    } else {
      switch status {
      case 400: code = .invalid
      case 401, 403: code = .unauthenticated
      case 404: code = .notFound
      case 409: code = .conflict
      case 413: code = .tooLarge
      case 429: code = .rateLimited
      case 500...: code = .serverError
      default: code = .requestFailed
      }
    }
    return CnctError(message, code: code, status: status, details: details)
  }
}

/// Holds the task so a cancellation that arrives from another thread can reach it.
private final class TaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionTask?
  private var cancelled = false

  func set(_ task: URLSessionTask) {
    lock.lock()
    defer { lock.unlock() }
    self.task = task
    if cancelled { task.cancel() }
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    task?.cancel()
  }
}

/// Hears how much of an upload's body has gone.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let report: @Sendable (Double) -> Void

  init(_ report: @escaping @Sendable (Double) -> Void) {
    self.report = report
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    // Short of 1: the last byte leaving is not the server having it. The transport says 1 once the
    // server has answered.
    report(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
  }
}
