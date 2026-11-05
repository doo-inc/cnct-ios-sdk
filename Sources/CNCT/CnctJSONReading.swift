import Foundation

// Reading the platform's JSON the way the Flutter SDK does: leniently, with a default for anything
// missing or of the wrong shape. A model that throws because the server added a field, or sent a
// number where a string was expected, takes a whole screen down for the sake of one label.

extension CnctJSON {
  /// Dart's `(json[key] as num?)?.toInt()`: any finite number, truncated towards zero.
  var truncatedInt: Int? {
    guard case .number(let value) = self, value.isFinite, abs(value) < 9.0e15 else { return nil }
    return Int(value)
  }

  /// Dart's `'$value'`, for the few fields that are tokens rather than prose — a slot's `startsAt`,
  /// an allowed value — and must survive arriving as a number.
  var text: String {
    switch self {
    case .null: return ""
    case .bool(let value): return value ? "true" : "false"
    case .number(let value):
      if value.rounded() == value, abs(value) < 9.0e15 { return String(Int(value)) }
      return String(value)
    case .string(let value): return value
    case .array, .object:
      guard let data = try? JSONEncoder().encode(self) else { return "" }
      return String(decoding: data, as: UTF8.self)
    }
  }

  /// The objects in an array under `key`, skipping anything that is not one — Dart's
  /// `whereType<Map>()`.
  func objects(_ key: String) -> [CnctJSON] {
    (self[key]?.arrayValue ?? []).filter { $0.objectValue != nil }
  }

  /// The object under `key`, or an empty one.
  func object(_ key: String) -> [String: CnctJSON] {
    self[key]?.objectValue ?? [:]
  }

  /// A whole number, for building a request.
  static func int(_ value: Int) -> CnctJSON { .number(Double(value)) }

  /// What kind of value this is, for an error message.
  var kind: String {
    switch self {
    case .null: return "null"
    case .bool: return "a boolean"
    case .number: return "a number"
    case .string: return "a string"
    case .array: return "an array"
    case .object: return "an object"
    }
  }

  /// This value as an object, or ``CnctErrorCode/badResponse``. Every endpoint this SDK calls answers
  /// with one, so anything else means the base URL points somewhere that is not CNCT.
  func requireObject() throws -> [String: CnctJSON] {
    guard case .object(let fields) = self else {
      throw CnctError("Expected an object from the server and got \(kind).", code: .badResponse)
    }
    return fields
  }
}

extension Dictionary where Key == String, Value == CnctJSON? {
  /// Drop the arguments that were not given, so nothing unasked-for is sent. The Dart SDK's
  /// collection-`if`, as a dictionary.
  func compacted() -> [String: CnctJSON] { compactMapValues { $0 } }
}

/// Parsing the platform's timestamps.
///
/// The platform sends ISO 8601 instants, usually with milliseconds and a `Z`. Dart's
/// `DateTime.tryParse` takes them with or without the fraction, with an offset, or as a bare date,
/// and so does this. A `Date` is an instant with no zone, so there is nothing to convert to the
/// device's clock here — formatting it in the customer's locale is the app's `DateFormatter`'s job.
enum CnctDates {
  private static let lock = NSLock()
  // Formatters are expensive to make and a transcript parses one timestamp per message. These are
  // only ever touched under the lock.
  nonisolated(unsafe) private static let formatters: [ISO8601DateFormatter] = {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    let day = ISO8601DateFormatter()
    day.formatOptions = [.withFullDate]
    return [fractional, whole, day]
  }()

  static func parse(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    lock.lock()
    defer { lock.unlock() }
    for formatter in formatters {
      if let date = formatter.date(from: raw) { return date }
    }
    return nil
  }
}
