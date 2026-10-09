import Foundation

public enum BulkJobKind: String, Codable, Sendable { case ingest, query }
public enum BulkIngestOperation: String, Codable, Sendable {
  case insert, update, upsert, delete, hardDelete
}
public enum BulkQueryOperation: String, Codable, Sendable { case query, queryAll }
public enum BulkJobState: String, Codable, Sendable {
  case open = "Open"
  case uploadComplete = "UploadComplete"
  case inProgress = "InProgress"
  case jobComplete = "JobComplete"
  case aborted = "Aborted"
  case failed = "Failed"
}
public struct BulkJobReference: Codable, Sendable, Equatable {
  public let id: String
  public let kind: BulkJobKind
  public let apiVersion: String
  public init(id: String, kind: BulkJobKind, apiVersion: String) throws {
    try validateIdentifier(id)
    _ = try SalesforceConfiguration(apiVersion: apiVersion)
    self.id = id
    self.kind = kind
    self.apiVersion = apiVersion
  }
  private enum CodingKeys: String, CodingKey { case id, kind, apiVersion }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: c.decode(String.self, forKey: .id), kind: c.decode(BulkJobKind.self, forKey: .kind),
      apiVersion: c.decode(String.self, forKey: .apiVersion))
  }
}
public struct BulkJobInfo: Decodable, Sendable {
  public let id: String
  public let state: BulkJobState
  public let object: String?
  public let operation: String?
  public let errorMessage: String?
  public let numberRecordsProcessed: Int?
  public let numberRecordsFailed: Int?
  public let columnDelimiter: SalesforceCSVDelimiter?
  public let lineEnding: SalesforceCSVLineEnding?
  public let apiVersion: Decimal?
  public var creationAPIVersion: String? {
    guard let apiVersion else { return nil }
    let text = NSDecimalNumber(decimal: apiVersion).stringValue
    return text.contains(".") ? text : text + ".0"
  }
}
public struct BulkJob: Sendable {
  public let reference: BulkJobReference
  public let info: BulkJobInfo
}
public struct BulkJobList: Sendable {
  public let done: Bool
  public let nextRecordsUrl: String?
  public let records: [BulkJob]
}
public enum BulkIngestResult: String, Sendable {
  case successful = "successfulResults"
  case failed = "failedResults"
  case unprocessed = "unprocessedrecords"
}
public struct BulkPolling: Sendable {
  public let interval: TimeInterval
  public let timeout: TimeInterval
  public init(interval: TimeInterval = 2, timeout: TimeInterval = 900) {
    self.interval = interval
    self.timeout = timeout
  }
}
public struct SalesforceBulk: Sendable {
  let client: SalesforceClient
  private func path(_ job: BulkJobReference) -> String {
    "/services/data/v\(job.apiVersion)/jobs/\(job.kind.rawValue)/\(pathComponent(job.id))"
  }
  private func attach(
    _ response: SalesforceResponse<BulkJobInfo>, kind: BulkJobKind, version: String
  ) throws -> SalesforceResponse<BulkJob> {
    SalesforceResponse(
      value: BulkJob(
        reference: try BulkJobReference(id: response.value.id, kind: kind, apiVersion: version),
        info: response.value), metadata: response.metadata)
  }
  public func createIngest(
    object: String, operation: BulkIngestOperation, externalIDField: String? = nil,
    delimiter: SalesforceCSVDelimiter = .comma, lineEnding: SalesforceCSVLineEnding = .lf
  ) async throws -> SalesforceResponse<BulkJob> {
    try validateIdentifier(object)
    if operation == .upsert && externalIDField == nil {
      throw SalesforceError.validation("Bulk upsert requires an external ID field")
    }
    if let externalIDField { try validateIdentifier(externalIDField) }
    struct Payload: Encodable, Sendable {
      let object: String
      let operation: BulkIngestOperation
      let externalIdFieldName: String?
      let columnDelimiter: SalesforceCSVDelimiter
      let lineEnding: SalesforceCSVLineEnding
      let contentType = "CSV"
    }
    let response = try await client.request(
      "POST", path: client.dataPath + "/jobs/ingest",
      payload: Payload(
        object: object, operation: operation, externalIdFieldName: externalIDField,
        columnDelimiter: delimiter, lineEnding: lineEnding), as: BulkJobInfo.self)
    return try attach(response, kind: .ingest, version: client.configuration.apiVersion)
  }
  public func createQuery(
    _ soql: String, operation: BulkQueryOperation = .query,
    delimiter: SalesforceCSVDelimiter = .comma, lineEnding: SalesforceCSVLineEnding = .lf
  ) async throws -> SalesforceResponse<BulkJob> {
    struct Payload: Encodable, Sendable {
      let operation: BulkQueryOperation
      let query: String
      let columnDelimiter: SalesforceCSVDelimiter
      let lineEnding: SalesforceCSVLineEnding
      let contentType = "CSV"
    }
    let response = try await client.request(
      "POST", path: client.dataPath + "/jobs/query",
      payload: Payload(
        operation: operation, query: soql, columnDelimiter: delimiter, lineEnding: lineEnding),
      as: BulkJobInfo.self)
    return try attach(response, kind: .query, version: client.configuration.apiVersion)
  }
  public func inspect(_ job: BulkJobReference) async throws -> SalesforceResponse<BulkJob> {
    try attach(
      await client.request("GET", path: path(job), as: BulkJobInfo.self), kind: job.kind,
      version: job.apiVersion)
  }
  public func list(_ kind: BulkJobKind, continuation: String? = nil) async throws
    -> SalesforceResponse<BulkJobList>
  {
    struct List: Decodable, Sendable {
      let done: Bool
      let nextRecordsUrl: String?
      let records: [BulkJobInfo]
    }
    let response = try await client.request(
      "GET", path: continuation ?? (client.dataPath + "/jobs/\(kind.rawValue)"), as: List.self)
    let jobs = try response.value.records.map {
      BulkJob(
        reference: try BulkJobReference(
          id: $0.id, kind: kind,
          apiVersion: $0.creationAPIVersion ?? client.configuration.apiVersion), info: $0)
    }
    return SalesforceResponse(
      value: BulkJobList(
        done: response.value.done, nextRecordsUrl: response.value.nextRecordsUrl, records: jobs),
      metadata: response.metadata)
  }
  public func upload(_ job: BulkJobReference, body: SalesforceRequestBody) async throws
    -> SalesforceResponse<EmptyResponse>
  {
    guard job.kind == .ingest else {
      throw SalesforceError.validation("Upload requires an ingest job")
    }
    return try await client.request(
      "PUT", path: path(job) + "/batches", body: body,
      headers: ["Content-Type": "text/csv", "Accept": "application/json"], as: EmptyResponse.self)
  }
  public func complete(_ job: BulkJobReference) async throws -> SalesforceResponse<BulkJob> {
    guard job.kind == .ingest else {
      throw SalesforceError.validation("Only ingest jobs require upload completion")
    }
    return try await state(job, .uploadComplete)
  }
  public func abort(_ job: BulkJobReference) async throws -> SalesforceResponse<BulkJob> {
    try await state(job, .aborted)
  }
  private func state(_ job: BulkJobReference, _ state: BulkJobState) async throws
    -> SalesforceResponse<BulkJob>
  {
    struct Payload: Encodable, Sendable { let state: BulkJobState }
    return try attach(
      await client.request(
        "PATCH", path: path(job), payload: Payload(state: state), as: BulkJobInfo.self),
      kind: job.kind, version: job.apiVersion)
  }
  public func delete(_ job: BulkJobReference) async throws -> SalesforceResponse<EmptyResponse> {
    try await client.request("DELETE", path: path(job), as: EmptyResponse.self)
  }
  public func waitUntilComplete(_ job: BulkJobReference, polling: BulkPolling = BulkPolling())
    async throws -> SalesforceResponse<BulkJob>
  {
    guard polling.interval > 0, polling.interval.isFinite, polling.timeout > 0,
      polling.timeout.isFinite
    else { throw SalesforceError.validation("Polling durations must be positive and finite") }
    let deadline = ContinuousClock.now.advanced(by: .seconds(polling.timeout))
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw SalesforceError.bulk("Polling timed out; job remains available")
      }
      let response = try await withThrowingTaskGroup(of: SalesforceResponse<BulkJob>.self) {
        group in
        group.addTask { try await self.inspect(job) }
        group.addTask {
          try await Task.sleep(until: deadline, clock: .continuous)
          throw SalesforceError.bulk("Polling timed out; job remains available")
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw CancellationError() }
        return value
      }
      switch response.value.info.state {
      case .jobComplete: return response
      case .failed, .aborted:
        throw SalesforceError.bulk(
          response.value.info.errorMessage ?? response.value.info.state.rawValue)
      default: break
      }
      try await Task.sleep(
        for: min(.seconds(polling.interval), ContinuousClock.now.duration(to: deadline)))
    }
  }
  public func ingestResults(_ job: BulkJobReference, result: BulkIngestResult) async throws
    -> SalesforceHTTPResponse
  {
    guard job.kind == .ingest else {
      throw SalesforceError.validation("Ingest results require an ingest job")
    }
    return try await client.stream(
      "GET", path: path(job) + "/\(result.rawValue)", headers: ["Accept": "text/csv"])
  }
  public func queryResults(_ job: BulkJobReference, locator: String? = nil, maxRecords: Int? = nil)
    async throws -> SalesforceHTTPResponse
  {
    guard job.kind == .query else {
      throw SalesforceError.validation("Query results require a query job")
    }
    var query: [URLQueryItem] = []
    if let locator { query.append(URLQueryItem(name: "locator", value: locator)) }
    if let maxRecords {
      guard maxRecords > 0 else { throw SalesforceError.validation("maxRecords must be positive") }
      query.append(URLQueryItem(name: "maxRecords", value: String(maxRecords)))
    }
    return try await client.stream(
      "GET", path: path(job) + "/results", query: query, headers: ["Accept": "text/csv"])
  }
  /// Emits the header once, validates headers on later pages, and fetches the next locator on demand.
  public func queryRows(
    _ job: BulkJobReference, delimiter: SalesforceCSVDelimiter = .comma, maxRecords: Int? = nil
  ) -> BulkQueryRows {
    BulkQueryRows(bulk: self, job: job, delimiter: delimiter, maxRecords: maxRecords)
  }
}
public struct BulkQueryRows: AsyncSequence, Sendable {
  public typealias Element = [String]
  let bulk: SalesforceBulk
  let job: BulkJobReference
  let delimiter: SalesforceCSVDelimiter
  let maxRecords: Int?
  public struct AsyncIterator: AsyncIteratorProtocol {
    let bulk: SalesforceBulk
    let job: BulkJobReference
    let delimiter: SalesforceCSVDelimiter
    let maxRecords: Int?
    var reader: CSVReader.AsyncIterator?
    var locator: String?
    var started = false
    var finished = false
    var header: [String]?
    var seen: Set<String> = []
    public mutating func next() async throws -> [String]? {
      try Task.checkCancellation()
      while !finished {
        if var current = reader {
          let row = try await current.next()
          reader = current
          if let row {
            guard row.count == header?.count else {
              throw SalesforceError.csv("Bulk row width differs from header")
            }
            return row
          }
          reader = nil
          if locator == nil {
            finished = true
            return nil
          }
        }
        if let locator {
          guard seen.insert(locator).inserted else {
            throw SalesforceError.bulk("Repeated Bulk result locator")
          }
        }
        let response = try await bulk.queryResults(
          job, locator: started ? locator : nil, maxRecords: maxRecords)
        started = true
        guard let next = response.metadata.header("Sforce-Locator") else {
          throw SalesforceError.bulk("Missing Sforce-Locator")
        }
        locator = next == "null" ? nil : next
        var current = CSVReader(response.body, delimiter: delimiter).makeAsyncIterator()
        guard let pageHeader = try await current.next() else {
          throw SalesforceError.csv("Missing Bulk CSV header")
        }
        reader = current
        if let header {
          guard pageHeader == header else { throw SalesforceError.csv("Bulk page headers differ") }
        } else {
          header = pageHeader
          return pageHeader
        }
      }
      return nil
    }
  }
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(bulk: bulk, job: job, delimiter: delimiter, maxRecords: maxRecords)
  }
}
