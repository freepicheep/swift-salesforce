import Foundation

public struct SalesforceRecords: Sendable {
  let client: SalesforceClient
  private func path(_ object: String) throws -> String {
    try validateIdentifier(object)
    return client.dataPath + "/sobjects/\(object)"
  }
  public func create<P: Encodable & Sendable>(_ object: String, payload: P) async throws
    -> SalesforceResponse<SaveResult>
  { try await client.request("POST", path: path(object), payload: payload, as: SaveResult.self) }
  public func retrieve<T: Decodable & Sendable>(
    _ object: String, id: String, fields: [String] = [], as type: T.Type
  ) async throws -> SalesforceResponse<T> {
    try await client.request(
      "GET", path: path(object) + "/\(pathComponent(id))",
      query: fields.isEmpty
        ? [] : [URLQueryItem(name: "fields", value: fields.joined(separator: ","))], as: type)
  }
  public func update<P: Encodable & Sendable>(_ object: String, id: String, payload: P) async throws
    -> SalesforceResponse<EmptyResponse>
  {
    try await client.request(
      "PATCH", path: path(object) + "/\(pathComponent(id))", payload: payload,
      as: EmptyResponse.self)
  }
  public func delete(_ object: String, id: String) async throws -> SalesforceResponse<EmptyResponse>
  {
    try await client.request(
      "DELETE", path: path(object) + "/\(pathComponent(id))", as: EmptyResponse.self)
  }
  public func retrieve<T: Decodable & Sendable>(
    _ object: String, externalIDField: String, value: String, as type: T.Type
  ) async throws -> SalesforceResponse<T> {
    try validateIdentifier(externalIDField)
    return try await client.request(
      "GET", path: path(object) + "/\(externalIDField)/\(pathComponent(value))", as: type)
  }
  /// Existing records produce HTTP 204 with no SaveResult; creation produces HTTP 201.
  public func upsert<P: Encodable & Sendable>(
    _ object: String, externalIDField: String, value: String, payload: P
  ) async throws -> SalesforceResponse<SaveResult?> {
    try validateIdentifier(externalIDField)
    let body = try await client.configuration.codecs.encode(payload)
    let response = try await client.stream(
      "PATCH", path: path(object) + "/\(externalIDField)/\(pathComponent(value))", body: .data(body)
    )
    let data = try await response.body.collect(maxBytes: client.configuration.maxJSONBytes)
    let result =
      data.isEmpty ? nil : try await client.configuration.codecs.decode(SaveResult.self, from: data)
    return SalesforceResponse(value: result, metadata: response.metadata)
  }
}
public struct QueryPage<Record: Decodable & Sendable>: Decodable, Sendable {
  public let totalSize: Int
  public let done: Bool
  public let records: [Record]
  public let nextRecordsUrl: String?
}
public struct SalesforceQueries: Sendable {
  let client: SalesforceClient
  public func page<T: Decodable & Sendable>(_ soql: String, queryAll: Bool = false, as type: T.Type)
    async throws -> SalesforceResponse<QueryPage<T>>
  {
    try await client.request(
      "GET", path: client.dataPath + (queryAll ? "/queryAll" : "/query"),
      query: [URLQueryItem(name: "q", value: soql)], as: QueryPage<T>.self)
  }
  public func continuation<T: Decodable & Sendable>(_ url: String, as type: T.Type) async throws
    -> SalesforceResponse<QueryPage<T>>
  { try await client.request("GET", path: url, as: QueryPage<T>.self) }
  public func pages<T: Decodable & Sendable>(
    _ soql: String, queryAll: Bool = false, as type: T.Type
  ) -> QueryPages<T> { QueryPages(client: client, soql: soql, queryAll: queryAll) }
  public func records<T: Decodable & Sendable>(
    _ soql: String, queryAll: Bool = false, as type: T.Type
  ) -> QueryRecords<T> { QueryRecords(pages: pages(soql, queryAll: queryAll, as: type)) }
}
public struct QueryPages<Record: Decodable & Sendable>: AsyncSequence, Sendable {
  public typealias Element = SalesforceResponse<QueryPage<Record>>
  let client: SalesforceClient
  let soql: String
  let queryAll: Bool
  public struct AsyncIterator: AsyncIteratorProtocol {
    let client: SalesforceClient
    let soql: String
    let queryAll: Bool
    var initial = true
    var nextURL: String?
    var visited: Set<String> = []
    public mutating func next() async throws -> Element? {
      try Task.checkCancellation()
      let response: Element
      if initial {
        initial = false
        response = try await client.queries.page(soql, queryAll: queryAll, as: Record.self)
      } else if let nextURL {
        guard visited.insert(nextURL).inserted else {
          throw SalesforceError.validation("Repeated query continuation")
        }
        response = try await client.queries.continuation(nextURL, as: Record.self)
      } else {
        return nil
      }
      if !response.value.done && response.value.nextRecordsUrl == nil {
        throw SalesforceError.decoding("Incomplete query page has no continuation")
      }
      nextURL = response.value.done ? nil : response.value.nextRecordsUrl
      return response
    }
  }
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(client: client, soql: soql, queryAll: queryAll)
  }
}
public struct QueryRecords<Record: Decodable & Sendable>: AsyncSequence, Sendable {
  public typealias Element = Record
  let pages: QueryPages<Record>
  public struct AsyncIterator: AsyncIteratorProtocol {
    var pages: QueryPages<Record>.AsyncIterator
    var records: [Record] = []
    var index = 0
    public mutating func next() async throws -> Record? {
      try Task.checkCancellation()
      while index == records.count {
        guard let page = try await pages.next() else { return nil }
        records = page.value.records
        index = 0
      }
      defer { index += 1 }
      return records[index]
    }
  }
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(pages: pages.makeAsyncIterator())
  }
}
public struct SalesforceSearch: Sendable {
  let client: SalesforceClient
  public func search<T: Decodable & Sendable>(_ sosl: String, as type: T.Type) async throws
    -> SalesforceResponse<T>
  {
    try await client.request(
      "GET", path: client.dataPath + "/search", query: [URLQueryItem(name: "q", value: sosl)],
      as: type)
  }
}

public struct CompositeSubrequest: Codable, Sendable {
  public let method: String
  public let url: String
  public let referenceId: String
  public let body: JSONValue?
  public let httpHeaders: [String: String]?
  public init(
    method: String, url: String, referenceID: String, body: JSONValue? = nil,
    headers: [String: String]? = nil
  ) {
    self.method = method
    self.url = url
    self.referenceId = referenceID
    self.body = body
    self.httpHeaders = headers
  }
}
public struct CompositeSubresponse: Decodable, Sendable {
  public let body: JSONValue
  public let httpHeaders: [String: String]
  public let httpStatusCode: Int
  public let referenceId: String
  public var isSuccess: Bool { (200..<300).contains(httpStatusCode) }
  public var errors: [APIError] {
    guard !isSuccess, case .array(let values) = body else { return [] }
    return values.compactMap { value in
      guard case .object(let object) = value, case .string(let code) = object["errorCode"],
        case .string(let message) = object["message"]
      else { return nil }
      return APIError(message: message, errorCode: code)
    }
  }
}
public struct CompositeResult: Decodable, Sendable {
  public let compositeResponse: [CompositeSubresponse]
  public var hasErrors: Bool { compositeResponse.contains { !$0.isSuccess } }
}
public struct BatchSubrequest: Encodable, Sendable {
  public let method: String
  public let url: String
  public let richInput: JSONValue?
  public init(method: String, url: String, body: JSONValue? = nil) {
    self.method = method
    self.url = url
    richInput = body
  }
}
public struct BatchResult: Decodable, Sendable {
  public struct Result: Decodable, Sendable {
    public let statusCode: Int
    public let result: JSONValue
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
  }
  public let hasErrors: Bool
  public let results: [Result]
}
public struct CompositeGraph: Encodable, Sendable {
  public let graphId: String
  public let compositeRequest: [CompositeSubrequest]
  public init(id: String, requests: [CompositeSubrequest]) {
    graphId = id
    compositeRequest = requests
  }
}
public struct GraphResult: Decodable, Sendable {
  public struct Graph: Decodable, Sendable {
    public let graphId: String
    public let isSuccessful: Bool
    public let graphResponse: JSONValue
  }
  public let graphs: [Graph]
}
public struct TreeResult: Decodable, Sendable {
  public struct Result: Decodable, Sendable {
    public let referenceId: String
    public let id: String?
    public let errors: [APIError]?
  }
  public let hasErrors: Bool
  public let results: [Result]
}
public struct SalesforceComposite: Sendable {
  let client: SalesforceClient
  private func validate(_ url: String) throws {
    guard url.hasPrefix("/services/data/"), !url.contains("://"), !url.contains("\\"),
      !(url.removingPercentEncoding ?? url).split(separator: "/").contains("..")
    else { throw SalesforceError.validation("Composite subrequest must be an API-relative URL") }
  }
  public func execute(_ requests: [CompositeSubrequest], allOrNone: Bool = false) async throws
    -> SalesforceResponse<CompositeResult>
  {
    guard !requests.isEmpty, requests.count <= 25,
      Set(requests.map(\.referenceId)).count == requests.count
    else { throw SalesforceError.validation("Composite requires 1...25 unique references") }
    for request in requests { try validate(request.url) }
    struct Payload: Encodable, Sendable {
      let allOrNone: Bool
      let compositeRequest: [CompositeSubrequest]
    }
    return try await client.request(
      "POST", path: client.dataPath + "/composite",
      payload: Payload(allOrNone: allOrNone, compositeRequest: requests), as: CompositeResult.self)
  }
  public func batch(_ requests: [BatchSubrequest], haltOnError: Bool = false) async throws
    -> SalesforceResponse<BatchResult>
  {
    guard !requests.isEmpty, requests.count <= 25 else {
      throw SalesforceError.validation("Batch requires 1...25 subrequests")
    }
    for request in requests { try validate(request.url) }
    struct Payload: Encodable, Sendable {
      let haltOnError: Bool
      let batchRequests: [BatchSubrequest]
    }
    return try await client.request(
      "POST", path: client.dataPath + "/composite/batch",
      payload: Payload(haltOnError: haltOnError, batchRequests: requests), as: BatchResult.self)
  }
  public func graphs(_ graphs: [CompositeGraph]) async throws -> SalesforceResponse<GraphResult> {
    guard !graphs.isEmpty, graphs.count <= 75,
      graphs.reduce(0, { $0 + $1.compositeRequest.count }) <= 500
    else { throw SalesforceError.validation("Invalid Graph size") }
    for graph in graphs { for request in graph.compositeRequest { try validate(request.url) } }
    struct Payload: Encodable, Sendable { let graphs: [CompositeGraph] }
    return try await client.request(
      "POST", path: client.dataPath + "/composite/graph", payload: Payload(graphs: graphs),
      as: GraphResult.self)
  }
  public func tree<P: Encodable & Sendable>(_ object: String, records: [P]) async throws
    -> SalesforceResponse<TreeResult>
  {
    try validateIdentifier(object)
    return try await client.request(
      "POST", path: client.dataPath + "/composite/tree/\(object)",
      payload: TreePayload(records: records), as: TreeResult.self)
  }
  public func create<P: Encodable & Sendable>(_ records: [P], allOrNone: Bool = false) async throws
    -> SalesforceResponse<[SaveResult]>
  { try await collection("POST", records: records, allOrNone: allOrNone) }
  public func update<P: Encodable & Sendable>(_ records: [P], allOrNone: Bool = false) async throws
    -> SalesforceResponse<[SaveResult]>
  { try await collection("PATCH", records: records, allOrNone: allOrNone) }
  public func upsert<P: Encodable & Sendable>(
    _ object: String, externalIDField: String, records: [P], allOrNone: Bool = false
  ) async throws -> SalesforceResponse<[SaveResult]> {
    try validateIdentifier(object)
    try validateIdentifier(externalIDField)
    return try await collection(
      "PATCH", suffix: "/\(object)/\(externalIDField)", records: records, allOrNone: allOrNone)
  }
  private func collection<P: Encodable & Sendable>(
    _ method: String, suffix: String = "", records: [P], allOrNone: Bool
  ) async throws -> SalesforceResponse<[SaveResult]> {
    guard !records.isEmpty, records.count <= 200 else {
      throw SalesforceError.validation("Collection requires 1...200 records")
    }
    return try await client.request(
      method, path: client.dataPath + "/composite/sobjects" + suffix,
      payload: CollectionPayload(allOrNone: allOrNone, records: records), as: [SaveResult].self)
  }
  public func retrieve<T: Decodable & Sendable>(
    _ object: String, ids: [String], fields: [String], as type: T.Type
  ) async throws -> SalesforceResponse<[T?]> {
    try validateIdentifier(object)
    guard !ids.isEmpty, ids.count <= 2000 else {
      throw SalesforceError.validation("Retrieve requires 1...2000 ids")
    }
    return try await client.request(
      "GET", path: client.dataPath + "/composite/sobjects/\(object)",
      query: [
        URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
        URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
      ], as: [T?].self)
  }
  public func delete(ids: [String], allOrNone: Bool = false) async throws -> SalesforceResponse<
    [SaveResult]
  > {
    guard !ids.isEmpty, ids.count <= 200 else {
      throw SalesforceError.validation("Delete requires 1...200 ids")
    }
    return try await client.request(
      "DELETE", path: client.dataPath + "/composite/sobjects",
      query: [
        URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
        URLQueryItem(name: "allOrNone", value: String(allOrNone)),
      ], as: [SaveResult].self)
  }
}

private struct TreePayload<T: Encodable & Sendable>: Encodable, Sendable { let records: [T] }
private struct CollectionPayload<T: Encodable & Sendable>: Encodable, Sendable {
  let allOrNone: Bool
  let records: [T]
}
