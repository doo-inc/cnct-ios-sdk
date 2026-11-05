import Foundation

/// A JSON value the SDK passes around before — or instead of — a typed model.
///
/// What the transport answers, and what a ``CnctError`` keeps as ``CnctError/details``. Typed
/// models are decoded from it; anything the SDK does not model yet is still reachable through it,
/// so a field the server adds tomorrow is not lost today.
public enum CnctJSON: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([CnctJSON])
  case object([String: CnctJSON])

  /// The value under `key`, for an object. Nil for anything else.
  public subscript(key: String) -> CnctJSON? {
    if case .object(let fields) = self { return fields[key] }
    return nil
  }

  /// The element at `index`, for an array. Nil for anything else or out of range.
  public subscript(index: Int) -> CnctJSON? {
    if case .array(let items) = self, items.indices.contains(index) { return items[index] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  /// The number as an `Int`, when it is a whole one.
  public var intValue: Int? {
    guard case .number(let value) = self, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
    return Int(value)
  }

  public var arrayValue: [CnctJSON]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: CnctJSON]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool { self == .null }

  /// Decode a typed model from this value.
  public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
    try decoder.decode(T.self, from: JSONEncoder().encode(self))
  }
}

extension CnctJSON: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([CnctJSON].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: CnctJSON].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value.")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension CnctJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: CnctJSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, CnctJSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
