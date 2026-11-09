import Foundation

#if canImport(ImageIO)
  import ImageIO
#endif

/// A file the visitor picked, on its way to the server.
public struct CnctUploadFile: Sendable, Hashable {
  public let data: Data
  /// The name the business sees. Kept as picked, Arabic and all.
  public let filename: String
  /// `image/jpeg`, `application/pdf`, … — see ``CnctChatAttachments/acceptedMimeTypes``.
  public let mimeType: String

  /// `mimeType` defaults to one worked out from the file name's extension.
  public init(data: Data, filename: String, mimeType: String? = nil) {
    self.data = data
    self.filename = filename
    self.mimeType = CnctChatAttachments.normalise(mimeType ?? CnctChatAttachments.mimeType(forFilename: filename))
  }

  /// True for a photo in Apple's own format, which the platform does not take — see
  /// ``CnctChatAttachments/prepare(_:)``.
  public var isHEIC: Bool {
    ["image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence"].contains(mimeType)
      || ["heic", "heif", "hif"].contains(CnctChatAttachments.fileExtension(filename))
  }

  public var bytes: Int { data.count }
}

/// What the platform takes, checked here first so a UI can say so before an upload starts.
///
/// The server enforces every one of these limits itself; checking them on the device as well is
/// what turns "the upload failed" after a minute on a slow connection into a sentence before it
/// begins.
public enum CnctChatAttachments {
  /// Files per message.
  public static let maxFiles = 10

  /// Bytes per file: 50 MB.
  public static let maxBytes = 50 * 1024 * 1024

  /// The longest side a photo is sent at. Larger photos are scaled down, never up.
  public static let maxPhotoPixels = 2560

  /// The JPEG quality a converted or scaled photo is written at.
  public static let photoQuality = 0.85

  /// Everything the platform accepts. HEIC is not among them: see ``prepare(_:)``.
  public static let acceptedMimeTypes: Set<String> = [
    "image/jpeg", "image/png", "image/webp", "image/gif",
    "audio/aac", "audio/mpeg", "audio/ogg", "audio/mp4", "audio/amr",
    "video/mp4", "video/3gpp", "video/quicktime",
    "application/pdf", "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "text/plain", "text/csv",
  ]

  /// Check a file before it is uploaded. Throws ``CnctErrorCode/tooMany`` for the eleventh file,
  /// ``CnctErrorCode/tooLarge`` for one over 50 MB, and ``CnctErrorCode/unsupportedType`` for a type
  /// the platform does not take.
  ///
  /// - Parameter alreadyPicked: How many files are already waiting to go with this message.
  public static func check(filename: String, mimeType: String, bytes: Int, alreadyPicked: Int = 0) throws {
    if alreadyPicked >= maxFiles {
      throw CnctError("Up to \(maxFiles) files at a time.", code: .tooMany)
    }
    if bytes > maxBytes {
      throw CnctError("\(filename) is over 50 MB.", code: .tooLarge)
    }
    if !acceptedMimeTypes.contains(normalise(mimeType)) {
      throw CnctError("\(filename) is not a kind of file this chat can send.", code: .unsupportedType)
    }
  }

  public static func check(_ file: CnctUploadFile, alreadyPicked: Int = 0) throws {
    try check(filename: file.filename, mimeType: file.mimeType, bytes: file.bytes, alreadyPicked: alreadyPicked)
  }

  /// The MIME type for a file name, from its extension — for a file from a picker that did not say.
  /// `application/octet-stream` for an extension this does not know, which ``check(_:alreadyPicked:)``
  /// then refuses.
  public static func mimeType(forFilename filename: String) -> String {
    switch fileExtension(filename) {
    case "jpg", "jpeg", "jpe": return "image/jpeg"
    case "png": return "image/png"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "heic", "hif": return "image/heic"
    case "heif": return "image/heif"
    case "aac": return "audio/aac"
    case "mp3", "mpga": return "audio/mpeg"
    case "ogg", "oga", "opus": return "audio/ogg"
    case "m4a": return "audio/mp4"
    case "amr": return "audio/amr"
    case "mp4", "m4v": return "video/mp4"
    case "3gp", "3gpp": return "video/3gpp"
    case "mov", "qt": return "video/quicktime"
    case "pdf": return "application/pdf"
    case "doc": return "application/msword"
    case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    case "txt", "text": return "text/plain"
    case "csv": return "text/csv"
    default: return "application/octet-stream"
    }
  }

  /// **Make a photo something the platform takes, at a size worth sending.**
  ///
  /// An iPhone takes photos in HEIC, which the platform does not accept — so a HEIC or HEIF image is
  /// converted to JPEG. A JPEG or PNG wider or taller than ``maxPhotoPixels`` is scaled down to it
  /// (never up), because a 48-megapixel photo is minutes of somebody's mobile data for a picture an
  /// operator looks at on a laptop. The photo's orientation is applied as it is redrawn, so it
  /// arrives the right way up; its metadata, location included, does not travel with it.
  ///
  /// Everything else — a GIF, a WebP, a document, a photo already small enough — is returned
  /// exactly as it was given. Where the device cannot read the image, it is returned unchanged too,
  /// and ``check(_:alreadyPicked:)`` says what is wrong with it.
  public static func prepare(_ file: CnctUploadFile) -> CnctUploadFile {
    #if canImport(ImageIO)
      let heic = file.isHEIC
      let png = file.mimeType == "image/png"
      guard heic || png || file.mimeType == "image/jpeg" else { return file }
      guard
        let source = CGImageSourceCreateWithData(file.data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
      else { return file }
      let longSide = max(width, height)
      if !heic && longSide <= maxPhotoPixels { return file }

      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(longSide, maxPhotoPixels),
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return file }
      let output = NSMutableData()
      let type = (png ? "public.png" : "public.jpeg") as CFString
      guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return file }
      let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: photoQuality]
      CGImageDestinationAddImage(destination, image, png ? nil : quality as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return file }

      let filename = heic ? renamed(file.filename, to: "jpg") : file.filename
      return CnctUploadFile(data: output as Data, filename: filename, mimeType: png ? "image/png" : "image/jpeg")
    #else
      return file
    #endif
  }

  // MARK: - Internals

  static func fileExtension(_ filename: String) -> String {
    guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return "" }
    return String(filename[filename.index(after: dot)...]).lowercased()
  }

  /// Lower case, parameters dropped, and the one misspelling every platform sends.
  static func normalise(_ mimeType: String) -> String {
    let bare = mimeType.split(separator: ";").first.map(String.init) ?? mimeType
    let lower = bare.trimmingCharacters(in: .whitespaces).lowercased()
    return lower == "image/jpg" ? "image/jpeg" : lower
  }

  static func renamed(_ filename: String, to newExtension: String) -> String {
    guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
      return "\(filename).\(newExtension)"
    }
    return "\(filename[..<dot]).\(newExtension)"
  }
}

/// A `multipart/form-data` body with one file part — what the attachments endpoint takes.
struct CnctMultipart {
  let boundary: String
  let body: Data

  var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  init(field: String, file: CnctUploadFile, boundary: String = "cnct-\(UUID().uuidString.lowercased())") {
    self.boundary = boundary
    // A quote or a line break in a file name would end the header early; nothing else in a name
    // needs escaping, and the rest of it — Arabic included — travels as UTF-8, as browsers send it.
    let name = file.filename
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    var body = Data()
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\n".utf8))
    body.append(Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8))
    body.append(file.data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    self.body = body
  }
}
