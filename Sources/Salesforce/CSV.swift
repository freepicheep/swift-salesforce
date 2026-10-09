import Foundation

public enum SalesforceCSVDelimiter: String, Codable, Sendable {
  case comma = "COMMA"
  case tab = "TAB"
  case pipe = "PIPE"
  case semicolon = "SEMICOLON"
  case caret = "CARET"
  case backquote = "BACKQUOTE"
  public var character: UInt8 {
    switch self {
    case .comma: 44
    case .tab: 9
    case .pipe: 124
    case .semicolon: 59
    case .caret: 94
    case .backquote: 96
    }
  }
}
public enum SalesforceCSVLineEnding: String, Codable, Sendable {
  case lf = "LF"
  case crlf = "CRLF"
  public var text: String { self == .lf ? "\n" : "\r\n" }
}
/// Parses UTF-8 bytes incrementally, including quotes, CRLF and characters split across chunks.
public struct CSVReader: AsyncSequence, Sendable {
  public typealias Element = [String]
  let bytes: SalesforceByteStream
  let delimiter: SalesforceCSVDelimiter
  let maxFieldBytes: Int
  let maxRowBytes: Int
  public init(
    _ bytes: SalesforceByteStream, delimiter: SalesforceCSVDelimiter = .comma,
    maxFieldBytes: Int = 8 * 1024 * 1024, maxRowBytes: Int = 32 * 1024 * 1024
  ) {
    self.bytes = bytes
    self.delimiter = delimiter
    self.maxFieldBytes = Swift.max(1, maxFieldBytes)
    self.maxRowBytes = Swift.max(1, maxRowBytes)
  }
  public struct AsyncIterator: AsyncIteratorProtocol {
    var input: SalesforceByteStream.AsyncIterator
    fileprivate var parser: CSVParser
    var chunk = Data()
    var index = 0
    var ended = false
    @concurrent public mutating func next() async throws -> [String]? {
      try Task.checkCancellation()
      guard !ended else { return nil }
      while true {
        if index < chunk.count {
          let b = chunk[index]
          index += 1
          if let row = try parser.consume(b) { return row }
        } else if let data = try await input.next() {
          chunk = data
          index = 0
        } else {
          ended = true
          return try parser.finish()
        }
      }
    }
  }
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      input: bytes.makeAsyncIterator(),
      parser: CSVParser(
        delimiter: delimiter.character, maxField: maxFieldBytes, maxRow: maxRowBytes))
  }
}
private struct CSVParser: Sendable {
  enum Mode { case plain, quoted, afterQuote }
  let delimiter: UInt8
  let maxField: Int
  let maxRow: Int
  var mode = Mode.plain
  var field: [UInt8] = []
  var row: [String] = []
  var skipLF = false
  var touched = false
  var firstField = true
  var rowBytes = 0
  var preamble: [UInt8] = []
  var preambleChecked = false
  mutating func consume(_ byte: UInt8) throws -> [String]? {
    if !preambleChecked {
      preamble.append(byte)
      let bom: [UInt8] = [0xef, 0xbb, 0xbf]
      if preamble == Array(bom.prefix(preamble.count)) {
        if preamble.count == 3 {
          preambleChecked = true
          preamble.removeAll()
        }
        return nil
      }
      preambleChecked = true
      let pending = preamble
      preamble.removeAll()
      var result: [String]?
      for byte in pending { if let row = try consumeContent(byte) { result = row } }
      return result
    }
    return try consumeContent(byte)
  }
  mutating func consumeContent(_ byte: UInt8) throws -> [String]? {
    if skipLF {
      skipLF = false
      if byte == 10 { return nil }
    }
    touched = true
    rowBytes += 1
    guard rowBytes <= maxRow else { throw SalesforceError.csv("Row exceeds byte limit") }
    switch mode {
    case .quoted:
      if byte == 34 { mode = .afterQuote } else { field.append(byte) }
    case .afterQuote:
      if byte == 34 {
        field.append(34)
        mode = .quoted
      } else if byte == delimiter {
        try endField()
        mode = .plain
      } else if byte == 10 || byte == 13 {
        return try endRow(cr: byte == 13)
      } else {
        throw SalesforceError.csv("Unexpected byte after closing quote")
      }
    case .plain:
      if byte == 34 {
        guard field.isEmpty else { throw SalesforceError.csv("Quote in unquoted field") }
        mode = .quoted
      } else if byte == delimiter {
        try endField()
      } else if byte == 10 || byte == 13 {
        return try endRow(cr: byte == 13)
      } else {
        field.append(byte)
      }
    }
    guard field.count <= maxField else { throw SalesforceError.csv("Field exceeds byte limit") }
    return nil
  }
  mutating func endField() throws {
    guard let string = String(bytes: field, encoding: .utf8) else {
      throw SalesforceError.csv("Invalid UTF-8")
    }
    var value = string
    if firstField {
      firstField = false
      if value.first == "\u{FEFF}" { value.removeFirst() }
    }
    row.append(value)
    field.removeAll(keepingCapacity: true)
  }
  mutating func endRow(cr: Bool) throws -> [String] {
    try endField()
    let result = row
    row.removeAll(keepingCapacity: true)
    mode = .plain
    skipLF = cr
    touched = false
    rowBytes = 0
    return result
  }
  mutating func finish() throws -> [String]? {
    if !preambleChecked {
      for byte in preamble { _ = try consumeContent(byte) }
      preamble.removeAll()
    }
    guard mode != .quoted else { throw SalesforceError.csv("Unterminated quoted field") }
    guard touched else { return nil }
    return try endRow(cr: false)
  }
}
public struct CSVWriter: Sendable {
  public let delimiter: SalesforceCSVDelimiter
  public let lineEnding: SalesforceCSVLineEnding
  public init(delimiter: SalesforceCSVDelimiter = .comma, lineEnding: SalesforceCSVLineEnding = .lf)
  {
    self.delimiter = delimiter
    self.lineEnding = lineEnding
  }
  @concurrent public func encode(_ row: [String]) async throws -> Data {
    try Task.checkCancellation()
    let separator = String(UnicodeScalar(delimiter.character))
    let text =
      row.map { field in
        if field.unicodeScalars.contains(where: {
          $0.value == UInt32(delimiter.character) || [10, 13, 34].contains($0.value)
        }) {
          return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
      }.joined(separator: separator) + lineEnding.text
    return Data(text.utf8)
  }
  public func stream(rows: [[String]]) -> SalesforceByteStream {
    let source = CSVRowsSource(rows: rows, writer: self)
    return SalesforceByteStream { try await source.next() }
  }
}
private actor CSVRowsSource {
  let rows: [[String]]
  let writer: CSVWriter
  var index = 0
  init(rows: [[String]], writer: CSVWriter) {
    self.rows = rows
    self.writer = writer
  }
  func next() async throws -> Data? {
    guard index < rows.count else { return nil }
    let row = rows[index]
    index += 1
    return try await writer.encode(row)
  }
}
