import CNCT
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(CoreGraphics) && canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif

/// **A scripted conversation that never touches a network** — for SwiftUI previews, screenshots, a
/// demo with no key, and the tests that hold the screen to the spec.
///
/// The same eight steps every CNCT SDK renders, in English or Arabic: the greeting; "Do you open on
/// Fridays?"; the assistant's answer with two choices; a photo; Sara's reply with an invoice; a line
/// with a phone number in it; a message that failed to send; and the team typing. Played through a
/// fake transport and a fake socket into a real ``CnctChatClient``, so what renders is the real
/// screen on the real headless state.
///
/// ```swift
/// CnctChatView(fixture: .ar)
/// ```
public enum CnctChatFixture {
  /// A chat client that plays the scripted conversation in `language`. Anything sent to it is
  /// echoed back as stored, files included, so a demo can be tried as well as looked at.
  public static func client(language: CnctChatLanguage = .en) -> CnctChatClient {
    let script = Script(language)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CnctFixtureProtocol.self]
    // swiftlint:disable:next force_try
    let config = try! CnctConfig(baseURL: "https://\(script.language.rawValue).\(host)")
    return CnctChatClient(
      config: config,
      credentials: try! CnctChatPublicKey(publicKey),  // swiftlint:disable:this force_try
      tokenStore: CnctMemoryTokenStore(),
      transport: CnctTransport(config: config, session: URLSession(configuration: configuration)),
      socketFactory: { _ in CnctFixtureSocket() }
    )
  }

  /// The theme the custom screenshots use: a red, square-ish corners, a serif and a logo of its own.
  /// Called "custom" because it is nobody's brand.
  public static var customTheme: CnctChatTheme {
    CnctChatTheme(primary: "#D7262E", cornerRadius: 8, font: .named("Georgia"), logo: logo.map(CnctChatLogo.image))
  }

  /// The words of the message the script leaves failed, so a screen can try it once.
  static func failedText(_ language: CnctChatLanguage) -> String { Script(language).failed }

  /// Two files the script leaves in the composer: a photo 40% of the way up, and a PDF already up.
  static func pickedFiles(_ language: CnctChatLanguage) -> [(file: CnctUploadFile, attachment: CnctChatAttachment?, progress: Double)] {
    let ar = language == .ar
    let photo = CnctUploadFile(data: picture(width: 480, height: 360, seed: 1) ?? Data(), filename: ar ? "إيصال.jpg" : "receipt.jpg")
    let pdf = CnctUploadFile(data: document, filename: ar ? "قائمة.pdf" : "menu.pdf")
    let stored = CnctChatAttachment(id: "fx_menu", kind: .document, mimeType: "application/pdf", filename: pdf.filename, bytes: 184_000)
    return [(photo, nil, 0.4), (pdf, stored, 1)]
  }

  static let host = "fixture.cnct.invalid"
  static let publicKey = "fixture"

  /// What each step says, in each language.
  struct Script {
    let language: CnctChatLanguage
    let business: String
    let greeting: String
    let question: String
    let answer: String
    let choices: [(String, String)]
    let assistant: String
    let operatorName: String
    let invoiceLine: String
    let mixed: String
    let failed: String

    init(_ language: CnctChatLanguage) {
      self.language = language == .ar ? .ar : .en
      if self.language == .ar {
        business = "مقهى تجريبي"
        greeting = "مرحبًا. كيف يمكننا مساعدتك؟"
        question = "هل تفتحون يوم الجمعة؟"
        answer = "نعم، من الساعة 2 ظهرًا حتى 10 مساءً. هل تود حجز زيارة؟"
        choices = [("book", "احجز زيارة"), ("person", "تحدث مع موظف")]
        assistant = "المساعد"
        operatorName = "سارة"
        invoiceLine = "شكرًا، هذه فاتورتك."
        mixed = "اتصلوا بي على +973 3311 2233 من فضلك"
        failed = "هل يمكنني الدفع بالبطاقة؟"
      } else {
        business = "Demo Café"
        greeting = "Hello. How can we help?"
        question = "Do you open on Fridays?"
        answer = "Yes, from 2pm to 10pm. Would you like to book a visit?"
        choices = [("book", "Book a visit"), ("person", "Talk to a person")]
        assistant = "Assistant"
        operatorName = "Sara"
        invoiceLine = "Thanks, here is your invoice."
        mixed = "Call me on +973 3311 2233 please"
        failed = "Can I pay by card?"
      }
    }

    private func at(_ minutesAgo: Double, from now: Date) -> CnctJSON {
      .string(Self.iso(now.addingTimeInterval(-minutesAgo * 60)))
    }

    static func iso(_ date: Date) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.string(from: date)
    }

    var inbox: CnctJSON {
      [
        "business": .string(business), "inbox": "App", "isActive": true, "greeting": .string(greeting),
        "requirePhone": false,
        "widget": [
          "brand": ["color": "#b52d93", "appearance": "auto", "language": "auto", "showBranding": true],
          "chat": [
            "allowAttachments": true, "allowEmoji": false, "allowEndConversation": true, "start": "details",
            "askForRating": true,
          ],
        ],
        "team": [["kind": "person", "name": .string(operatorName), "avatar": nil]],
        "availability": ["open": true, "assistant": true, "replyMinutes": 3],
      ]
    }

    func conversation(status: String = "OPEN", rating: CnctJSON = .null) -> CnctJSON {
      [
        "id": "fx_conversation", "status": .string(status), "startedAt": at(9, from: Date()),
        "closedAt": status == "CLOSED" ? .string(Self.iso(Date())) : .null,
        "withPerson": true,
        "assignee": ["kind": "person", "name": .string(operatorName), "avatar": nil],
        "seenAt": nil, "ratable": .bool(status == "CLOSED"), "rating": rating,
      ]
    }

    var messages: [CnctJSON] {
      let now = Date()
      let assistantSender: CnctJSON = ["kind": "ai", "name": .string(assistant), "mascot": nil, "colour": nil]
      let operatorSender: CnctJSON = ["kind": "person", "name": .string(operatorName), "avatar": nil]
      let numbered = choices.enumerated().map { "\($0.offset + 1). \($0.element.1)" }.joined(separator: "\n")
      return [
        message("fx_1", "SYSTEM", greeting, at(9, from: now)),
        message("fx_2", "CALLER", question, at(8.5, from: now), clientKey: "fx_key_2"),
        message(
          "fx_3", "AI", "\(answer)\n\(numbered)", at(8, from: now), sender: assistantSender,
          flow: [
            "text": .string(answer), "layout": "buttons",
            "choices": .array(choices.map { ["id": .string($0.0), "title": .string($0.1)] }),
          ]),
        message(
          "fx_4", "CALLER", "", at(6, from: now), clientKey: "fx_key_4",
          attachments: [["id": "fx_photo", "kind": "IMAGE", "mimeType": "image/jpeg", "filename": "photo.jpg", "bytes": 1_200_000]]),
        message(
          "fx_5", "OPERATOR", invoiceLine, at(4, from: now), sender: operatorSender,
          attachments: [
            ["id": "fx_invoice", "kind": "DOCUMENT", "mimeType": "application/pdf", "filename": "invoice.pdf", "bytes": 220_000]
          ]),
        message("fx_6", "CALLER", mixed, at(2, from: now), clientKey: "fx_key_6"),
      ]
    }

    private func message(
      _ id: String, _ speaker: String, _ body: String, _ createdAt: CnctJSON,
      clientKey: String? = nil, sender: CnctJSON = .null, flow: CnctJSON = .null, attachments: [CnctJSON] = []
    ) -> CnctJSON {
      [
        "id": .string(id), "speaker": .string(speaker), "type": "TEXT", "body": .string(body), "createdAt": createdAt,
        "clientKey": clientKey.map(CnctJSON.string) ?? .null, "sender": sender, "flow": flow,
        "attachments": .array(attachments),
      ]
    }

    var session: CnctJSON {
      [
        "token": "fixture-token",
        "visitor": ["displayName": "Layla", "anonymous": false, "identified": false],
        "conversation": conversation(),
        "messages": .array(messages),
      ]
    }
  }

  // MARK: - The pictures

  /// The photo the visitor sent: a landscape, drawn rather than shipped.
  static let photo: Data = picture(width: 1600, height: 1067, seed: 0) ?? Data()

  /// The custom theme's logo: a white mark on the theme's red.
  static let logo: Data? = {
    #if canImport(CoreGraphics) && canImport(ImageIO)
      return draw(width: 160, height: 160, type: "public.png") { context, width, height in
        context.setFillColor(red: 0xD7 / 255, green: 0x26 / 255, blue: 0x2E / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        // A cup: a bowl, a handle and a saucer.
        context.fill(CGRect(x: 44, y: 70, width: 60, height: 40))
        context.fillEllipse(in: CGRect(x: 44, y: 48, width: 60, height: 44))
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setLineWidth(9)
        context.strokeEllipse(in: CGRect(x: 92, y: 64, width: 28, height: 28))
        context.fill(CGRect(x: 30, y: 38, width: 90, height: 9))
      }
    #else
      return nil
    #endif
  }()

  static func picture(width: Int, height: Int, seed: Int) -> Data? {
    #if canImport(CoreGraphics) && canImport(ImageIO)
      return draw(width: width, height: height, type: "public.jpeg") { context, width, height in
        let w = CGFloat(width), h = CGFloat(height)
        let space = CGColorSpaceCreateDeviceRGB()
        let sky: [CGFloat] = seed == 0 ? [0.36, 0.62, 0.92, 1, 0.98, 0.80, 0.55, 1] : [0.93, 0.93, 0.90, 1, 0.80, 0.80, 0.76, 1]
        if let gradient = CGGradient(colorSpace: space, colorComponents: sky, locations: [0, 1], count: 2) {
          context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.35), options: [.drawsAfterEndLocation])
        }
        if seed == 0 {
          context.setFillColor(red: 1, green: 0.86, blue: 0.35, alpha: 1)
          context.fillEllipse(in: CGRect(x: w * 0.68, y: h * 0.62, width: w * 0.12, height: w * 0.12))
          context.setFillColor(red: 0.20, green: 0.48, blue: 0.30, alpha: 1)
          context.fillEllipse(in: CGRect(x: -w * 0.2, y: -h * 0.55, width: w * 0.9, height: h * 0.95))
          context.setFillColor(red: 0.28, green: 0.58, blue: 0.34, alpha: 1)
          context.fillEllipse(in: CGRect(x: w * 0.3, y: -h * 0.6, width: w * 1.0, height: h * 0.9))
        } else {
          // A receipt: a white slip with lines on it.
          context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
          context.fill(CGRect(x: w * 0.25, y: h * 0.08, width: w * 0.5, height: h * 0.84))
          context.setFillColor(red: 0.55, green: 0.57, blue: 0.6, alpha: 1)
          for line in 0..<7 {
            let y = h * 0.78 - CGFloat(line) * h * 0.09
            context.fill(CGRect(x: w * 0.31, y: y, width: w * (line % 3 == 0 ? 0.38 : 0.28), height: h * 0.025))
          }
        }
      }
    #else
      return nil
    #endif
  }

  #if canImport(CoreGraphics) && canImport(ImageIO)
    private static func draw(
      width: Int, height: Int, type: String, _ paint: (CGContext, Int, Int) -> Void
    ) -> Data? {
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      paint(context, width, height)
      guard let image = context.makeImage() else { return nil }
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
      CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return output as Data
    }
  #endif

  /// A one-page PDF that says "Invoice".
  static let document: Data = {
    let content = "BT /F1 28 Tf 72 720 Td (Invoice) Tj ET"
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(pdf.utf8.count)
      pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(pdf.utf8)
  }()
}

/// The fixture's server: answers every visitor call from the script.
final class CnctFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host?.hasSuffix(CnctChatFixture.host) == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    guard let url = request.url else { return }
    let language: CnctChatLanguage = url.host?.hasPrefix("ar.") == true ? .ar : .en
    let script = CnctChatFixture.Script(language)
    let body = request.httpBody ?? Self.drain(request.httpBodyStream)
    let (status, data, type) = Self.answer(request.httpMethod ?? "GET", url.path, body, script)
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["content-type": type])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func json(_ value: CnctJSON) -> Data {
    (try? JSONEncoder().encode(value)) ?? Data()
  }

  static func answer(_ method: String, _ path: String, _ body: Data?, _ script: CnctChatFixture.Script)
    -> (Int, Data, String)
  {
    let key = CnctChatFixture.publicKey
    let sent = body.flatMap { try? JSONDecoder().decode(CnctJSON.self, from: $0) } ?? .null
    switch (method, path) {
    case ("GET", "/api/chat/public/\(key)"):
      return (200, json(script.inbox), "application/json")
    case ("POST", "/api/chat/public/\(key)/session"), ("GET", "/api/chat/public/session"):
      return (200, json(script.session), "application/json")
    case ("POST", "/api/chat/public/\(key)/identify"):
      return (200, json(["token": "fixture-token", "visitor": ["displayName": "Layla", "identified": true]]), "application/json")
    case ("POST", "/api/chat/public/messages"):
      let words = sent["body"]?.stringValue ?? ""
      if words == script.failed {
        return (503, json(["error": "The fixture never delivers this one."]), "application/json")
      }
      let stored: CnctJSON = [
        "id": .string("fx_sent_\(UUID().uuidString.prefix(8))"), "speaker": "CALLER", "type": "TEXT",
        "body": .string(words), "createdAt": .string(CnctChatFixture.Script.iso(Date())),
        "clientKey": sent["clientKey"] ?? .null,
        "attachments": .array((sent["attachmentIds"]?.arrayValue ?? []).map { id in
          ["id": id, "kind": "DOCUMENT", "mimeType": "application/octet-stream"]
        }),
      ]
      return (200, json(stored), "application/json")
    case ("POST", "/api/chat/public/attachments"):
      let (filename, type) = multipartFile(body ?? Data())
      let kind = type.hasPrefix("image/") ? "IMAGE" : type.hasPrefix("video/") ? "VIDEO" : type.hasPrefix("audio/") ? "AUDIO" : "DOCUMENT"
      let attachment: CnctJSON = [
        "id": .string("fx_upload_\(UUID().uuidString.prefix(8))"), "kind": .string(kind), "mimeType": .string(type),
        "filename": .string(filename), "bytes": .number(Double(body?.count ?? 0)),
      ]
      return (201, json(["attachment": attachment]), "application/json")
    case ("GET", "/api/chat/public/attachments/fx_photo"):
      return (200, CnctChatFixture.photo, "image/jpeg")
    case ("GET", "/api/chat/public/attachments/fx_invoice"), ("GET", "/api/chat/public/attachments/fx_menu"):
      return (200, CnctChatFixture.document, "application/pdf")
    case ("GET", "/api/chat/public/conversations"):
      return (200, json(["conversations": [script.conversation()]]), "application/json")
    case ("GET", "/api/chat/public/conversations/fx_conversation"):
      return (200, json(["conversation": script.conversation(status: "CLOSED"), "messages": .array(script.messages)]), "application/json")
    case ("POST", "/api/chat/public/conversations/fx_conversation/read"):
      return (204, Data(), "application/json")
    case ("POST", "/api/chat/public/conversations/fx_conversation/rating"):
      let rating: CnctJSON = ["score": sent["score"] ?? .null, "comment": sent["comment"] ?? .null]
      return (200, json(["conversation": script.conversation(status: "CLOSED", rating: rating)]), "application/json")
    case ("POST", "/api/chat/public/profile"):
      return (200, json(["visitor": ["displayName": sent["displayName"] ?? "", "anonymous": false]]), "application/json")
    case ("POST", "/api/chat/public/close"):
      return (200, json(["ok": true]), "application/json")
    default:
      return (404, json(["error": "Not in the script."]), "application/json")
    }
  }

  /// The file name and type a multipart body declares — enough for the fixture to echo an upload.
  static func multipartFile(_ body: Data) -> (String, String) {
    let head = String(decoding: body.prefix(2048), as: UTF8.self)
    func value(after marker: String, until end: String) -> String? {
      guard let start = head.range(of: marker) else { return nil }
      let rest = head[start.upperBound...]
      guard let stop = rest.range(of: end) else { return nil }
      return String(rest[..<stop.lowerBound])
    }
    return (
      value(after: "filename=\"", until: "\"\r\n") ?? "file",
      value(after: "Content-Type: ", until: "\r\n") ?? "application/octet-stream"
    )
  }

  private static func drain(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}

/// The fixture's socket: authenticates, then keeps the team typing.
final class CnctFixtureSocket: CnctSocket, @unchecked Sendable {
  let events: AsyncStream<CnctSocketEvent>
  private let continuation: AsyncStream<CnctSocketEvent>.Continuation
  private let lock = NSLock()
  private var typing: Task<Void, Never>?

  init() {
    (events, continuation) = AsyncStream.makeStream(of: CnctSocketEvent.self)
  }

  func send(_ text: String) {
    guard let frame = try? JSONDecoder().decode(CnctJSON.self, from: Data(text.utf8)) else { return }
    switch frame["type"]?.stringValue {
    case "auth":
      // No socket sends: the script's failed message has to go over HTTP to fail.
      continuation.yield(.message(#"{"type":"authenticated","accepts":["ping","typing"]}"#))
      lock.lock()
      typing?.cancel()
      // The platform sends a start and never a stop; a client clears the indicator after a few
      // seconds. Saying it again inside that is what keeps the fixture's last step on screen.
      typing = Task { [continuation] in
        while !Task.isCancelled {
          continuation.yield(.message(#"{"type":"chat.typing","payload":{}}"#))
          try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
      }
      lock.unlock()
    case "ping":
      continuation.yield(.message(#"{"type":"pong"}"#))
    default:
      return
    }
  }

  func close(code: Int, reason: String?) {
    lock.lock()
    typing?.cancel()
    typing = nil
    lock.unlock()
    continuation.finish()
  }
}
