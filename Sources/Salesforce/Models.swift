import Foundation

public enum SalesforceError: Error, Sendable {
  case validation(String)
  case authentication(String)
  case tokenStorage(String)
  case http(status: Int, body: Data)
  case salesforce(status: Int, errors: [APIError])
  case decoding(String)
  case csv(String)
  case bulk(String)
}
public struct APIError: Codable, Sendable, Equatable {
  public let message: String
  public let errorCode: String
  public let fields: [String]?
  public init(message: String, errorCode: String, fields: [String]? = nil) {
    self.message = message
    self.errorCode = errorCode
    self.fields = fields
  }
}
/// Decimal JSON numbers are retained as Decimal rather than converted to Double.
public enum JSONValue: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Decimal)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Decimal.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}
/// Removing a key omits it from a payload; assigning .null explicitly clears a field.
public struct SalesforceRecord: Codable, Sendable, Equatable {
  public var fields: [String: JSONValue]
  public init(_ fields: [String: JSONValue] = [:]) { self.fields = fields }
  public subscript(_ key: String) -> JSONValue? {
    get { fields[key] }
    set { fields[key] = newValue }
  }
  public init(from decoder: any Decoder) throws { fields = try [String: JSONValue](from: decoder) }
  public func encode(to encoder: any Encoder) throws { try fields.encode(to: encoder) }
}
public struct SalesforceDate: Codable, Sendable, Hashable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int
  public init(year: Int, month: Int, day: Int) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = DateComponents(year: year, month: month, day: day)
    guard (1...9999).contains(year), let date = calendar.date(from: parts),
      calendar.dateComponents([.year, .month, .day], from: date) == parts
    else { throw SalesforceError.validation("Invalid date") }
    self.year = year
    self.month = month
    self.day = day
  }
  public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
  public init(from decoder: any Decoder) throws {
    let s = try decoder.singleValueContainer().decode(String.self)
    let p = s.split(separator: "-", omittingEmptySubsequences: false)
    guard s.count == 10, p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
      p.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }), let y = Int(p[0]),
      let m = Int(p[1]), let d = Int(p[2])
    else { throw SalesforceError.decoding("Invalid Salesforce date: \(s)") }
    try self.init(year: y, month: m, day: d)
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(description)
  }
}
public struct SalesforceCodecs: Sendable {
  public let encoder: @Sendable () -> JSONEncoder
  public let decoder: @Sendable () -> JSONDecoder
  public init(
    encoder: @escaping @Sendable () -> JSONEncoder = SalesforceCodecs.makeEncoder,
    decoder: @escaping @Sendable () -> JSONDecoder = SalesforceCodecs.makeDecoder
  ) {
    self.encoder = encoder
    self.decoder = decoder
  }
  public static func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .custom { date, encoder in
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var c = encoder.singleValueContainer()
      try c.encode(f.string(from: date))
    }
    return e
  }
  public static func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
      let s = try decoder.singleValueContainer().decode(String.self)
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = f.date(from: s) { return date }
      f.formatOptions = [.withInternetDateTime]
      if let date = f.date(from: s) { return date }
      let legacy = DateFormatter()
      legacy.locale = Locale(identifier: "en_US_POSIX")
      legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
      guard let date = legacy.date(from: s) else {
        throw SalesforceError.decoding("Invalid datetime: \(s)")
      }
      return date
    }
    return d
  }
  @concurrent public func encode<T: Encodable & Sendable>(_ value: T) async throws -> Data {
    try encoder().encode(value)
  }
  @concurrent public func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data)
    async throws -> T
  {
    do { return try decoder().decode(type, from: data) } catch is CancellationError {
      throw CancellationError()
    } catch { throw SalesforceError.decoding(String(describing: error)) }
  }
}
public struct HTTPMetadata: Sendable {
  public let status: Int
  public let headers: [String: String]
  public init(status: Int, headers: [String: String] = [:]) {
    self.status = status
    self.headers = headers
  }
  public func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
  public var apiLimits: [String: APILimit] {
    var result: [String: APILimit] = [:]
    for entry in (header("Sforce-Limit-Info") ?? "").split(separator: ";") {
      let pair = entry.split(separator: "=", maxSplits: 1)
      guard pair.count == 2 else { continue }
      let numbers = pair[1].split(separator: "/")
      guard numbers.count == 2, let used = Int(numbers[0]), let total = Int(numbers[1]) else {
        continue
      }
      result[pair[0].trimmingCharacters(in: .whitespaces)] = APILimit(used: used, total: total)
    }
    return result
  }
}
public struct APILimit: Sendable, Equatable {
  public let used: Int
  public let total: Int
}
public struct SalesforceResponse<Value: Sendable>: Sendable {
  public let value: Value
  public let metadata: HTTPMetadata
  public var apiLimits: [String: APILimit] { metadata.apiLimits }
  public init(value: Value, metadata: HTTPMetadata) {
    self.value = value
    self.metadata = metadata
  }
}
public struct EmptyResponse: Codable, Sendable { public init() {} }
public struct SaveResult: Codable, Sendable {
  public let id: String?
  public let success: Bool
  public let errors: [APIError]
  public let created: Bool?
}
public enum SOQL {
  public static func literal(_ value: String) -> String {
    "'"
      + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "'", with: "\\'"
      ).replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t") + "'"
  }
}
public enum SOSL {
  public static func literal(_ value: String) -> String {
    var out = ""
    for c in value {
      if "\\?&|!{}[]()^~*:\"'+-".contains(c) { out.append("\\") }
      out.append(c)
    }
    return out
  }
}
func pathComponent(_ value: String) -> String {
  value.addingPercentEncoding(
    withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
}
func validateIdentifier(_ value: String) throws {
  guard !value.isEmpty,
    value.unicodeScalars.allSatisfy({
      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
    })
  else { throw SalesforceError.validation("Invalid Salesforce identifier") }
}
