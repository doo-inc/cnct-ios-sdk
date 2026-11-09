import Foundation
import Testing

@testable import CNCT

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif

/// The parts of a `multipart/form-data` body, as a server reads them.
private struct Part {
  let headers: [String: String]
  let data: Data
}

private func parts(_ body: Data, contentType: String?) -> [Part] {
  guard let contentType, let range = contentType.range(of: "boundary=") else { return [] }
  let boundary = Data("--\(contentType[range.upperBound...])".utf8)
  var found: [Part] = []
  var cursor = body.startIndex
  while let start = body.range(of: boundary, in: cursor..<body.endIndex) {
    let afterBoundary = start.upperBound
    guard let next = body.range(of: boundary, in: afterBoundary..<body.endIndex) else { break }
    let chunk = body[afterBoundary..<next.lowerBound]
    if let split = chunk.range(of: Data("\r\n\r\n".utf8)) {
      let head = String(decoding: chunk[chunk.startIndex..<split.lowerBound], as: UTF8.self)
      var headers: [String: String] = [:]
      for line in head.split(separator: "\r\n") {
        let pair = line.split(separator: ":", maxSplits: 1)
        if pair.count == 2 {
          headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
        }
      }
      var data = Data(chunk[split.upperBound...])
      if data.suffix(2) == Data("\r\n".utf8) { data.removeLast(2) }
      found.append(Part(headers: headers, data: data))
    }
    cursor = next.lowerBound
  }
  return found
}

private func caught(_ body: () throws -> Void) -> CnctError? {
  do {
    try body()
    return nil
  } catch {
    return error as? CnctError
  }
}

private func uploadServer(status: Int = 201, answer: CnctJSON? = nil) -> VisitorServer {
  let api = VisitorServer()
  api.on("POST", "/api/chat/public/attachments") { request in
    let body = request.body ?? Data()
    let part = parts(body, contentType: request.header("content-type")).first
    let filename = part?.headers["content-disposition"]?.components(separatedBy: "filename=\"").last?.dropLast() ?? ""
    return (
      status,
      answer ?? [
        "attachment": [
          "id": "att_new", "kind": "IMAGE", "mimeType": .string(part?.headers["content-type"] ?? ""),
          "filename": .string(String(filename)), "bytes": .number(Double(part?.data.count ?? 0)),
        ]
      ]
    )
  }
  return api
}

@Suite("Attachments")
struct AttachmentTests {
  @Test("one file goes up as multipart, in a part named file, with the session header")
  func multipartShape() async throws {
    let api = uploadServer()
    let chat = api.client()
    try await chat.start()
    let pdf = Data("%PDF-1.4 a small invoice".utf8)
    let attachment = try await chat.upload(CnctUploadFile(data: pdf, filename: "فاتورة \"May\".pdf"))

    let request = try #require(api.requests("POST", "/api/chat/public/attachments").first)
    #expect(request.header("x-chat-token") == "visitor-token-1")
    #expect(request.header("authorization") == nil)
    let contentType = try #require(request.header("content-type"))
    #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    let found = parts(request.body ?? Data(), contentType: contentType)
    #expect(found.count == 1)
    let part = try #require(found.first)
    #expect(part.headers["content-disposition"] == #"form-data; name="file"; filename="فاتورة \"May\".pdf""#)
    #expect(part.headers["content-type"] == "application/pdf")
    #expect(part.data == pdf)
    #expect(attachment.id == "att_new")
    // What was sent is on this device already, so the bubble that carries it fetches nothing.
    #expect(await chat.cachedAttachment("att_new") == pdf)
    await chat.dispose()
  }

  @Test("upload progress runs from 0 to 1, never backwards")
  func progress() async throws {
    let api = uploadServer()
    let chat = api.client()
    try await chat.start()
    let heard = Locked<[Double]>([])
    _ = try await chat.upload(CnctUploadFile(data: Data(repeating: 7, count: 300_000), filename: "notes.txt")) { value in
      heard.set(heard.get + [value])
    }
    let values = heard.get
    #expect(values.first == 0)
    #expect(values.last == 1)
    #expect(values.allSatisfy { (0...1).contains($0) })
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    await chat.dispose()
  }

  @Test("the eleventh file, a file over 50 MB and a type the chat does not take are refused before upload")
  func checksBeforeUpload() async throws {
    let tooMany = caught {
      try CnctChatAttachments.check(filename: "a.jpg", mimeType: "image/jpeg", bytes: 10, alreadyPicked: 10)
    }
    #expect(tooMany?.code == .tooMany)
    try CnctChatAttachments.check(filename: "a.jpg", mimeType: "image/jpeg", bytes: 10, alreadyPicked: 9)

    let api = uploadServer()
    let chat = api.client()
    try await chat.start()
    let big = CnctUploadFile(data: Data(count: CnctChatAttachments.maxBytes + 1), filename: "film.mp4")
    #expect(await caughtCnctError { _ = try await chat.upload(big) }?.code == .tooLarge)
    let exe = CnctUploadFile(data: Data([0x4d, 0x5a]), filename: "setup.exe")
    #expect(exe.mimeType == "application/octet-stream")
    #expect(await caughtCnctError { _ = try await chat.upload(exe) }?.code == .unsupportedType)
    let zip = CnctUploadFile(data: Data([1]), filename: "x.zip", mimeType: "application/zip")
    #expect(await caughtCnctError { _ = try await chat.upload(zip) }?.code == .unsupportedType)
    #expect(api.requests("POST", "/api/chat/public/attachments").isEmpty)
    await chat.dispose()
  }

  @Test("exactly 50 MB is allowed")
  func boundary() throws {
    try CnctChatAttachments.check(filename: "film.mp4", mimeType: "video/mp4", bytes: CnctChatAttachments.maxBytes)
  }

  @Test("no session, no upload")
  func noSession() async {
    let chat = uploadServer().client()
    let error = await caughtCnctError { _ = try await chat.upload(CnctUploadFile(data: Data([1]), filename: "a.txt")) }
    #expect(error?.code == .noSession)
    await chat.dispose()
  }

  @Test(
    "the server's refusals are named for what they mean here",
    arguments: [
      (403, CnctErrorCode.attachmentsDisabled),
      (409, .conversationClosed),
      (413, .tooLarge),
      (422, .unsupportedType),
      (503, .attachmentsDisabled),
      (500, .serverError),
    ]
  )
  func refusals(status: Int, code: CnctErrorCode) async throws {
    let api = uploadServer(status: status, answer: ["error": "A sentence for a person."])
    let chat = api.client()
    try await chat.start()
    let error = await caughtCnctError { _ = try await chat.upload(CnctUploadFile(data: Data([1]), filename: "a.txt")) }
    #expect(error?.code == code)
    #expect(error?.status == status)
    #expect(error?.message == "A sentence for a person.")
    await chat.dispose()
  }

  @Test("a code the server names itself is kept")
  func serverCodeWins() async throws {
    let api = uploadServer(status: 403, answer: ["error": "Nope", "code": "unauthenticated"])
    let chat = api.client()
    try await chat.start()
    let error = await caughtCnctError { _ = try await chat.upload(CnctUploadFile(data: Data([1]), filename: "a.txt")) }
    #expect(error?.code == .unauthenticated)
    await chat.dispose()
  }

  @Test("an answer without an attachment id is a bad response, not an attachment")
  func badAnswer() async throws {
    let api = uploadServer(answer: ["ok": true])
    let chat = api.client()
    try await chat.start()
    let error = await caughtCnctError { _ = try await chat.upload(CnctUploadFile(data: Data([1]), filename: "a.txt")) }
    #expect(error?.code == .badResponse)
    await chat.dispose()
  }

  @Test("a downloaded attachment is fetched once and then answered from memory")
  func downloadCache() async throws {
    let api = VisitorServer()
    api.on("GET", "/api/chat/public/attachments/att_1") { _ in (200, "PDF") }
    let chat = api.client()
    try await chat.start()
    #expect(await chat.cachedAttachment("att_1") == nil)
    let first = try await chat.downloadAttachment("att_1")
    let second = try await chat.downloadAttachment("att_1")
    #expect(first == second)
    #expect(api.requests("GET", "/api/chat/public/attachments/att_1").count == 1)
    #expect(api.requests("GET", "/api/chat/public/attachments/att_1").first?.header("x-chat-token") == "visitor-token-1")
    await chat.dispose()
  }

  @Test(
    "a MIME type is worked out from the file name",
    arguments: [
      ("IMG_0001.JPG", "image/jpeg"), ("scan.png", "image/png"), ("IMG_0002.HEIC", "image/heic"),
      ("voice.m4a", "audio/mp4"), ("clip.mov", "video/quicktime"), ("menu.pdf", "application/pdf"),
      ("cv.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
      ("sheet.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
      ("list.csv", "text/csv"), ("README", "application/octet-stream"),
    ]
  )
  func mimeTypes(filename: String, mimeType: String) {
    #expect(CnctChatAttachments.mimeType(forFilename: filename) == mimeType)
  }

  @Test("an image/jpg from a picker is image/jpeg, and HEIC is never accepted as it is")
  func normalised() {
    #expect(CnctUploadFile(data: Data(), filename: "a", mimeType: "image/JPG").mimeType == "image/jpeg")
    #expect(CnctUploadFile(data: Data(), filename: "a.heic").isHEIC)
    #expect(!CnctChatAttachments.acceptedMimeTypes.contains("image/heic"))
  }

  @Test("anything that is not a photo is sent exactly as it was given")
  func untouched() {
    let pdf = CnctUploadFile(data: Data("%PDF".utf8), filename: "menu.pdf")
    #expect(CnctChatAttachments.prepare(pdf) == pdf)
    let gif = CnctUploadFile(data: Data("GIF89a".utf8), filename: "wave.gif")
    #expect(CnctChatAttachments.prepare(gif) == gif)
  }

  #if canImport(ImageIO)
    @Test("a HEIC photo becomes a JPEG, the right size, with a .jpg name")
    func heicToJPEG() throws {
      let heic = CnctUploadFile(data: tinyHEIC, filename: "IMG_0001.HEIC")
      #expect(heic.isHEIC)
      let prepared = CnctChatAttachments.prepare(heic)
      #expect(prepared.mimeType == "image/jpeg")
      #expect(prepared.filename == "IMG_0001.jpg")
      #expect(Array(prepared.data.prefix(3)) == [0xFF, 0xD8, 0xFF])
      let (width, height) = try #require(pixelSize(prepared.data))
      #expect(width == 64)
      #expect(height == 48)
      try CnctChatAttachments.check(prepared)
    }

    @Test("a photo over 2560 px is scaled down to it, keeping its shape")
    func downscale() throws {
      let large = CnctUploadFile(data: try jpeg(width: 3200, height: 1800), filename: "wide.jpg")
      let prepared = CnctChatAttachments.prepare(large)
      let (width, height) = try #require(pixelSize(prepared.data))
      #expect(width == 2560)
      #expect(height == 1440)
      #expect(prepared.mimeType == "image/jpeg")
      #expect(prepared.filename == "wide.jpg")
    }

    @Test("a photo already small enough is never scaled up, nor touched")
    func neverUpscale() throws {
      let small = CnctUploadFile(data: try jpeg(width: 800, height: 600), filename: "small.jpg")
      #expect(CnctChatAttachments.prepare(small) == small)
    }

    @Test("the upload converts a HEIC before it checks it")
    func uploadConverts() async throws {
      let api = uploadServer()
      let chat = api.client()
      try await chat.start()
      _ = try await chat.upload(CnctUploadFile(data: tinyHEIC, filename: "IMG_0001.heic"))
      let request = try #require(api.requests("POST", "/api/chat/public/attachments").first)
      let part = try #require(parts(request.body ?? Data(), contentType: request.header("content-type")).first)
      #expect(part.headers["content-type"] == "image/jpeg")
      #expect(part.headers["content-disposition"]?.hasSuffix(#"filename="IMG_0001.jpg""#) == true)
      await chat.dispose()
    }

    private func pixelSize(_ data: Data) -> (Int, Int)? {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
      else { return nil }
      return (width, height)
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
      let context = try #require(
        CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
      context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let image = try #require(context.makeImage())
      let output = NSMutableData()
      let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      #expect(CGImageDestinationFinalize(destination))
      return output as Data
    }
  #endif
}

@Suite("Multipart")
struct MultipartTests {
  @Test("the body is one part between two boundaries, ending with the closing one")
  func shape() {
    let file = CnctUploadFile(data: Data("hello".utf8), filename: "a\nb.txt")
    let multipart = CnctMultipart(field: "file", file: file, boundary: "B")
    let text = String(decoding: multipart.body, as: UTF8.self)
    #expect(
      text
        == "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a b.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--B--\r\n"
    )
    #expect(multipart.contentType == "multipart/form-data; boundary=B")
  }
}
