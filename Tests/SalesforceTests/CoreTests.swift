import Foundation
import Testing

@testable import Salesforce

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

actor FixtureTransport: SalesforceTransport {
  var requests: [SalesforceHTTPRequest] = []
  var responses: [SalesforceHTTPResponse]
  init(_ responses: [SalesforceHTTPResponse]) { self.responses = responses }
  func execute(_ request: SalesforceHTTPRequest) throws -> SalesforceHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw SalesforceError.validation("Unexpected request") }
    return responses.removeFirst()
  }
}
func fixture(_ text: String = "", status: Int = 200, headers: [String: String] = [:])
  -> SalesforceHTTPResponse
{
  SalesforceHTTPResponse(
    metadata: HTTPMetadata(status: status, headers: headers), body: .data(Data(text.utf8)))
}
let instance = URL(string: "https://example.my.salesforce.com")!
func client(
  _ transport: any SalesforceTransport, version: String = "66.0",
  provider: (any SalesforceTokenProvider)? = nil
) throws -> SalesforceClient {
  SalesforceClient(
    configuration: try SalesforceConfiguration(
      apiVersion: version, retry: RetryPolicy(baseDelay: 0, maxDelay: 0)),
    tokenProvider: provider
      ?? AccessTokenProvider(SalesforceSession(accessToken: "secret", instanceURL: instance)),
    transport: transport)
}
struct Account: Codable, Sendable, Equatable {
  let Id: String
  let Name: String
}

@Test func numericVersionRequired() throws {
  for version in ["", "latest", "v66.0", "66", "66..0", "0.0", "66.0/limits", "٦٦.٠"] {
    #expect(throws: SalesforceError.self) { try SalesforceConfiguration(apiVersion: version) }
  }
  _ = try SalesforceConfiguration(apiVersion: "66.0")
}
@Test func dynamicDecimalAndNull() async throws {
  let codecs = SalesforceCodecs()
  let record = try await codecs.decode(
    SalesforceRecord.self,
    from: Data("{\"Amount\":123456789.123456789,\"Clear\":null,\"Parent\":{\"Name\":\"A\"}}".utf8))
  #expect(record["Amount"] == .number(Decimal(string: "123456789.123456789")!))
  #expect(record["Clear"] == .null)
  #expect(record["Omitted"] == nil)
  let roundtrip = try await codecs.decode(SalesforceRecord.self, from: codecs.encode(record))
  #expect(record == roundtrip)
}
@Test func dates() async throws {
  let codecs = SalesforceCodecs()
  let date = try SalesforceDate(year: 2024, month: 2, day: 29)
  #expect(try await codecs.decode(SalesforceDate.self, from: codecs.encode(date)) == date)
  #expect(throws: SalesforceError.self) { try SalesforceDate(year: 2025, month: 2, day: 29) }
  for text in ["2026-01-01T12:00:00.123Z", "2026-01-01T12:00:00Z", "2026-01-01T12:00:00.123+0000"] {
    let value = try await codecs.decode(Date.self, from: Data("\"\(text)\"".utf8))
    #expect(value.timeIntervalSince1970 > 0)
  }
}
@Test func recordCRUDAndExternalIDs() async throws {
  let t = FixtureTransport([
    fixture("{\"id\":\"001\",\"success\":true,\"errors\":[]}", status: 201),
    fixture("{\"Id\":\"001\",\"Name\":\"A\"}"), fixture(status: 204), fixture(status: 204),
    fixture("{\"Id\":\"001\",\"Name\":\"A\"}"), fixture(status: 204),
  ])
  let c = try client(t)
  let payload = SalesforceRecord(["Name": .string("A"), "Clear__c": .null])
  #expect(try await c.records.create("Account", payload: payload).value.success)
  #expect(
    try await c.records.retrieve("Account", id: "001", fields: ["Id", "Name"], as: Account.self)
      .value.Name == "A")
  _ = try await c.records.update("Account", id: "001", payload: payload)
  _ = try await c.records.delete("Account", id: "001")
  _ = try await c.records.retrieve(
    "Account", externalIDField: "External__c", value: "a/b +?", as: Account.self)
  #expect(
    try await c.records.upsert(
      "Account", externalIDField: "External__c", value: "a/b +?", payload: payload
    ).value == nil)
  let requests = await t.requests
  #expect(requests.map(\.method) == ["POST", "GET", "PATCH", "DELETE", "GET", "PATCH"])
  #expect(requests[4].url.absoluteString.hasSuffix("/External__c/a%2Fb%20%2B%3F"))
  guard case .data(let bytes) = requests[0].body else {
    Issue.record("No payload")
    return
  }
  #expect(String(decoding: bytes, as: UTF8.self).contains("\"Clear__c\":null"))
}
@Test func lazyPaginationAndQueryAll() async throws {
  let t = FixtureTransport([
    fixture(
      "{\"totalSize\":2,\"done\":false,\"records\":[{\"Id\":\"1\",\"Name\":\"A\"}],\"nextRecordsUrl\":\"/services/data/v66.0/query/next\"}"
    ), fixture("{\"totalSize\":2,\"done\":true,\"records\":[{\"Id\":\"2\",\"Name\":\"B\"}]}"),
  ])
  let c = try client(t)
  var iterator = c.queries.records("SELECT Id, Name FROM Account", queryAll: true, as: Account.self)
    .makeAsyncIterator()
  #expect(await t.requests.isEmpty)
  #expect(try await iterator.next()?.Id == "1")
  #expect(await t.requests.count == 1)
  #expect(try await iterator.next()?.Id == "2")
  #expect(try await iterator.next() == nil)
  let requests = await t.requests
  #expect(requests[0].url.path.hasSuffix("queryAll"))
  #expect(requests[1].url.path.hasSuffix("query/next"))
}
@Test func untrustedDestinationsNeverReceiveCredentials() async throws {
  let t = FixtureTransport([])
  let c = try client(t)
  for path in [
    "https://evil.example/services/data/v66.0/limits", "//evil.example/services/data/v66.0/limits",
    "/services/data/../oauth2/token", "/services/data/%2e%2e/oauth2/token",
    "/services/data/%5cother", "/other",
    "https://u:p@example.my.salesforce.com/services/data/v66.0/limits",
  ] {
    await #expect(throws: SalesforceError.self) {
      try await c.request("GET", path: path, as: SalesforceRecord.self)
    }
  }
  #expect(await t.requests.isEmpty)
}
@Test func compositePartialFailures() async throws {
  let t = FixtureTransport([
    fixture(
      "{\"compositeResponse\":[{\"body\":{\"id\":\"001\"},\"httpHeaders\":{},\"httpStatusCode\":201,\"referenceId\":\"ok\"},{\"body\":[{\"errorCode\":\"INVALID_FIELD\",\"message\":\"Bad field\"}],\"httpHeaders\":{},\"httpStatusCode\":400,\"referenceId\":\"bad\"}]}"
    )
  ])
  let result = try await client(t).composite.execute([
    CompositeSubrequest(
      method: "POST", url: "/services/data/v66.0/sobjects/Account", referenceID: "ok"),
    CompositeSubrequest(
      method: "GET", url: "/services/data/v66.0/sobjects/Bad", referenceID: "bad"),
  ])
  #expect(result.value.hasErrors)
  #expect(result.value.compositeResponse[1].errors.first?.errorCode == "INVALID_FIELD")
}
@Test func retryReadsNeverDuplicateWrites() async throws {
  let t = FixtureTransport([
    fixture(status: 503), fixture(status: 429, headers: ["Retry-After": "0"]),
    fixture("{}", headers: ["Sforce-Limit-Info": "api-usage=12/5000; per-app-api-usage=2/100"]),
  ])
  let value = try await client(t).limits()
  #expect(value.apiLimits["api-usage"]?.used == 12)
  #expect(await t.requests.count == 3)
  let writes = FixtureTransport([fixture(status: 503), fixture("{}")])
  await #expect(throws: SalesforceError.self) {
    try await client(writes).records.create("Account", payload: SalesforceRecord())
  }
  #expect(await writes.requests.count == 1)
  let exhausted = FixtureTransport([
    fixture(status: 503), fixture(status: 503), fixture(status: 503), fixture("{}"),
  ])
  await #expect(throws: SalesforceError.self) { try await client(exhausted).limits() }
  #expect(await exhausted.requests.count == 3)
}
actor Counter {
  var value = 0
  func increment() { value += 1 }
}
actor MemoryStore: SalesforceTokenStore {
  var value: SalesforceSession?
  let fails: Bool
  init(_ value: SalesforceSession? = nil, fails: Bool = false) {
    self.value = value
    self.fails = fails
  }
  func load() -> SalesforceSession? { value }
  func save(_ session: SalesforceSession) throws {
    if fails { throw SalesforceError.validation("Storage failure") }
    value = session
  }
}
@Test func sharedRenewalAndStaleFailures() async throws {
  let counter = Counter()
  let store = MemoryStore()
  let auth = SalesforceAuthentication(
    session: SalesforceSession(
      accessToken: "old", instanceURL: instance, refreshToken: "old-refresh"), store: store
  ) { _ in
    await counter.increment()
    try await Task.sleep(for: .milliseconds(30))
    return SalesforceSession(accessToken: "new", instanceURL: instance, refreshToken: "rotated")
  }
  let old = try await auth.credentials()
  try await withThrowingTaskGroup(of: SalesforceCredentials.self) { group in
    for _ in 0..<20 { group.addTask { try await auth.renew(invalidating: old.generation) } }
    for try await token in group { #expect(token.session.accessToken == "new") }
  }
  #expect(await counter.value == 1)
  #expect(await store.value?.refreshToken == "rotated")
  #expect(try await auth.renew(invalidating: old.generation).session.accessToken == "new")
  #expect(await counter.value == 1)
}
@Test func cancelledWaiterDoesNotCancelRenewal() async throws {
  let counter = Counter()
  let auth = SalesforceAuthentication { _ in
    await counter.increment()
    try await Task.sleep(for: .milliseconds(50))
    return SalesforceSession(accessToken: "new", instanceURL: instance)
  }
  let cancelled = Task { try await auth.credentials() }
  let other = Task { try await auth.credentials() }
  try await Task.sleep(for: .milliseconds(10))
  cancelled.cancel()
  #expect(try await other.value.session.accessToken == "new")
  await #expect(throws: CancellationError.self) { try await cancelled.value }
  #expect(await counter.value == 1)
}
@Test func persistenceFailureKeepsRenewedMemorySession() async throws {
  let auth = SalesforceAuthentication(store: MemoryStore(fails: true)) { _ in
    SalesforceSession(accessToken: "renewed", instanceURL: instance, refreshToken: "rotated")
  }
  await #expect(throws: SalesforceError.self) { try await auth.credentials() }
  #expect(await auth.currentSession()?.accessToken == "renewed")
  #expect(try await auth.credentials().session.refreshToken == "rotated")
}
@Test func invalidSessionRenewsOnceAndStreamIsNotReplayed() async throws {
  let counter = Counter()
  let auth = SalesforceAuthentication(
    session: SalesforceSession(accessToken: "old", instanceURL: instance)
  ) { _ in
    await counter.increment()
    return SalesforceSession(accessToken: "new", instanceURL: instance)
  }
  let invalid = "[{\"errorCode\":\"INVALID_SESSION_ID\",\"message\":\"Expired\"}]"
  let t = FixtureTransport([fixture(invalid, status: 401), fixture("{}")])
  _ = try await client(t, provider: auth).limits()
  #expect(await counter.value == 1)
  #expect(await t.requests.last?.headers["Authorization"] == "Bearer new")
  let streamed = FixtureTransport([fixture(invalid, status: 401), fixture("{}")])
  await #expect(throws: SalesforceError.self) {
    try await client(streamed, provider: auth).stream(
      "PUT", path: "/services/data/v66.0/jobs/ingest/1/batches", body: .stream(.data(Data())))
  }
  #expect(await streamed.requests.count == 1)
  let repeated = FixtureTransport([
    fixture(invalid, status: 401), fixture(invalid, status: 401), fixture("{}"),
  ])
  await #expect(throws: SalesforceError.self) {
    try await client(repeated, provider: auth).limits()
  }
  #expect(await repeated.requests.count == 2)
}
@Test func oauthPKCEAndState() async throws {
  let t = FixtureTransport([
    fixture(
      "{\"access_token\":\"a\",\"instance_url\":\"https://org.my.salesforce.com\",\"refresh_token\":\"r\"}"
    )
  ])
  let oauth = SalesforceOAuth(clientID: "client", transport: t)
  let auth = try oauth.authorization(redirectURI: URL(string: "myapp://oauth/callback")!)
  let query = URLComponents(url: auth.url, resolvingAgainstBaseURL: false)!.queryItems!
  #expect(query.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
  #expect(auth.verifier.count == 43)
  await #expect(throws: SalesforceError.self) {
    try await oauth.exchange(
      callback: URL(string: "myapp://oauth/callback?code=x&state=bad")!, authorization: auth)
  }
  #expect(await t.requests.isEmpty)
  let session = try await oauth.exchange(
    callback: URL(string: "myapp://oauth/callback?code=a%2Bb&state=\(auth.state)")!,
    authorization: auth)
  #expect(session.refreshToken == "r")
  guard case .data(let body) = await t.requests.first?.body else {
    Issue.record("Missing OAuth body")
    return
  }
  #expect(String(decoding: body, as: UTF8.self).contains("code=a%2Bb"))
}
@Test func refreshPreservesAndRotatesToken() async throws {
  let t = FixtureTransport([
    fixture("{\"access_token\":\"a\",\"instance_url\":\"https://org.my.salesforce.com\"}"),
    fixture(
      "{\"access_token\":\"b\",\"instance_url\":\"https://org.my.salesforce.com\",\"refresh_token\":\"new\"}"
    ),
  ])
  let oauth = SalesforceOAuth(clientID: "c", transport: t)
  let original = SalesforceSession(accessToken: "x", instanceURL: instance, refreshToken: "old")
  #expect(try await oauth.refresh(original).refreshToken == "old")
  #expect(try await oauth.refresh(original).refreshToken == "new")
}
@Test func csvChunkedRoundTrip() async throws {
  let rows = [
    ["Id", "Name", "Notes"], ["1", "😃 café", "line1\r\nline2"], ["2", "a,\"b\"", ""], ["", "", ""],
  ]
  for delimiter in [SalesforceCSVDelimiter.comma, .tab, .pipe, .semicolon, .caret, .backquote] {
    let data = try await CSVWriter(delimiter: delimiter, lineEnding: .crlf).stream(rows: rows)
      .collect()
    for chunkSize in [1, 2, 7, 65_536] {
      var result: [[String]] = []
      for try await row in CSVReader(.data(data, chunkSize: chunkSize), delimiter: delimiter) {
        result.append(row)
      }
      #expect(result == rows)
    }
  }
}
@Test func csvMalformedAndLimits() async throws {
  for text in ["\"unterminated", "a\"b", "\"a\"x"] {
    await #expect(throws: SalesforceError.self) {
      for try await _ in CSVReader(.data(Data(text.utf8), chunkSize: 1)) {}
    }
  }
  await #expect(throws: SalesforceError.self) {
    for try await _ in CSVReader(.data(Data([0xff, 10]))) {}
  }
  await #expect(throws: SalesforceError.self) {
    for try await _ in CSVReader(.data(Data("12345".utf8)), maxFieldBytes: 4) {}
  }
  var result: [[String]] = []
  for try await row in CSVReader(
    .data(Data("\u{FEFF}\"Id\",Name\r\n1,A\r\n2,B".utf8), chunkSize: 1))
  { result.append(row) }
  #expect(result == [["Id", "Name"], ["1", "A"], ["2", "B"]])
}
@Test func bulkVersionLocatorsAndHeaders() async throws {
  let t = FixtureTransport([
    fixture("Id,Name\n1,A\n", headers: ["Sforce-Locator": "next +"]),
    fixture("Id,Name\n2,B\n", headers: ["Sforce-Locator": "null"]),
  ])
  let c = try client(t, version: "67.0")
  let job = try BulkJobReference(id: "750abc", kind: .query, apiVersion: "66.0")
  var iterator = c.bulk.queryRows(job).makeAsyncIterator()
  #expect(await t.requests.isEmpty)
  #expect(try await iterator.next() == ["Id", "Name"])
  #expect(try await iterator.next() == ["1", "A"])
  #expect(await t.requests.count == 1)
  #expect(try await iterator.next() == ["2", "B"])
  #expect(try await iterator.next() == nil)
  let requests = await t.requests
  #expect(requests.allSatisfy { $0.url.path.contains("v66.0") })
  #expect(
    URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
      == "next +")
  let mismatch = FixtureTransport([
    fixture("Id\n1\n", headers: ["Sforce-Locator": "next"]),
    fixture("Other\n2\n", headers: ["Sforce-Locator": "null"]),
  ])
  await #expect(throws: SalesforceError.self) {
    for try await _ in try client(mismatch).bulk.queryRows(job) {}
  }
}
@Test func bulkLifecycleAndPolling() async throws {
  let t = FixtureTransport([
    fixture("{\"id\":\"750abc\",\"state\":\"Open\"}"), fixture(status: 201),
    fixture("{\"id\":\"750abc\",\"state\":\"UploadComplete\"}"),
    fixture("{\"id\":\"750abc\",\"state\":\"InProgress\"}"),
    fixture("{\"id\":\"750abc\",\"state\":\"JobComplete\"}"), fixture(status: 204),
  ])
  let c = try client(t)
  let job = try await c.bulk.createIngest(object: "Account", operation: .insert).value
  _ = try await c.bulk.upload(job.reference, body: .data(Data("Name\nA\n".utf8)))
  _ = try await c.bulk.complete(job.reference)
  #expect(
    try await c.bulk.waitUntilComplete(
      job.reference, polling: BulkPolling(interval: 0.001, timeout: 1)
    ).value.info.state == .jobComplete)
  _ = try await c.bulk.delete(job.reference)
  #expect(await t.requests.map(\.method) == ["POST", "PUT", "PATCH", "GET", "GET", "DELETE"])
}
@Test func literalEscaping() {
  #expect(SOQL.literal("a'b\\c\n") == "'a\\'b\\\\c\\n'")
  #expect(SOSL.literal("a?b*") == "a\\?b\\*")
}

@Test func cancellationDuringRetryAndPollingNeverAbortsJob() async throws {
  let retryTransport = FixtureTransport([fixture(status: 503), fixture("{}")])
  let configuration = try SalesforceConfiguration(
    apiVersion: "66.0", retry: RetryPolicy(baseDelay: 10, maxDelay: 10, jitter: false))
  let c = SalesforceClient(
    configuration: configuration,
    tokenProvider: AccessTokenProvider(SalesforceSession(accessToken: "x", instanceURL: instance)),
    transport: retryTransport)
  let request = Task { try await c.limits() }
  try await Task.sleep(for: .milliseconds(30))
  request.cancel()
  await #expect(throws: CancellationError.self) { try await request.value }
  #expect(await retryTransport.requests.count == 1)
  let pollingTransport = FixtureTransport([fixture("{\"id\":\"750abc\",\"state\":\"InProgress\"}")])
  let job = try BulkJobReference(id: "750abc", kind: .query, apiVersion: "66.0")
  let poll = Task {
    try await client(pollingTransport).bulk.waitUntilComplete(
      job, polling: BulkPolling(interval: 10, timeout: 20))
  }
  try await Task.sleep(for: .milliseconds(30))
  poll.cancel()
  await #expect(throws: CancellationError.self) { try await poll.value }
  #expect(await pollingTransport.requests.map(\.method) == ["GET"])
}
@Test func descriptionsSearchAndCompositeFamilies() async throws {
  let t = FixtureTransport([
    fixture("[]"), fixture("{}"), fixture("{}"), fixture("{}"), fixture("{\"searchRecords\":[]}"),
    fixture(
      "{\"hasErrors\":true,\"results\":[{\"statusCode\":400,\"result\":[{\"errorCode\":\"BAD\"}]}]}"
    ),
    fixture(
      "{\"graphs\":[{\"graphId\":\"g\",\"isSuccessful\":false,\"graphResponse\":{\"compositeResponse\":[]}}]}"
    ),
    fixture(
      "{\"hasErrors\":true,\"results\":[{\"referenceId\":\"r\",\"errors\":[{\"message\":\"bad\",\"errorCode\":\"INVALID_FIELD\"}]}]}"
    ),
    fixture(
      "[{\"id\":null,\"success\":false,\"errors\":[{\"message\":\"bad\",\"errorCode\":\"INVALID_FIELD\"}]}]"
    ), fixture("[null]"),
  ])
  let c = try client(t)
  _ = try await c.versions()
  _ = try await c.resources()
  _ = try await c.objects()
  _ = try await c.describe("Account")
  _ = try await c.search.search("FIND {a} RETURNING Account(Id)", as: SalesforceRecord.self)
  #expect(
    try await c.composite.batch([BatchSubrequest(method: "GET", url: c.dataPath + "/limits")]).value
      .hasErrors)
  #expect(
    try await c.composite.graphs([
      CompositeGraph(
        id: "g",
        requests: [
          CompositeSubrequest(method: "GET", url: c.dataPath + "/limits", referenceID: "r")
        ])
    ]).value.graphs.first?.isSuccessful == false)
  #expect(try await c.composite.tree("Account", records: [SalesforceRecord()]).value.hasErrors)
  #expect(try await c.composite.create([SalesforceRecord()]).value.first?.success == false)
  #expect(
    try await c.composite.retrieve("Account", ids: ["001"], fields: ["Id"], as: Account.self).value
      .first! == nil)
}
@Test func bulkListingAbortDeleteAndIngestResults() async throws {
  let t = FixtureTransport([
    fixture("{\"id\":\"750abc\",\"state\":\"UploadComplete\"}"),
    fixture("{\"done\":true,\"records\":[{\"id\":\"750abc\",\"state\":\"InProgress\"}]}"),
    fixture("{\"id\":\"750abc\",\"state\":\"Aborted\"}"), fixture(status: 204),
    fixture("sf__Id,Name\n001,A\n"),
  ])
  let c = try client(t)
  let queryJob = try await c.bulk.createQuery("SELECT Id FROM Account", operation: .queryAll).value
  #expect(try await c.bulk.list(.query).value.records.first?.reference.apiVersion == "66.0")
  #expect(try await c.bulk.abort(queryJob.reference).value.info.state == .aborted)
  _ = try await c.bulk.delete(queryJob.reference)
  let ingest = try BulkJobReference(id: "750ingest", kind: .ingest, apiVersion: "65.0")
  let results = try await c.bulk.ingestResults(ingest, result: .unprocessed)
  #expect(try await results.body.collect() == Data("sf__Id,Name\n001,A\n".utf8))
  #expect(
    await t.requests.last?.url.path
      == "/services/data/v65.0/jobs/ingest/750ingest/unprocessedrecords")
}

private actor DelayedTransport: SalesforceTransport {
  var calls = 0
  func execute(_ request: SalesforceHTTPRequest) async throws -> SalesforceHTTPResponse {
    calls += 1
    try await Task.sleep(for: .seconds(10))
    return fixture("{\"id\":\"750abc\",\"state\":\"InProgress\"}")
  }
}
@Test func pollingTimeoutCancelsInspectionWithoutAbortingRemoteJob() async throws {
  let t = DelayedTransport()
  let c = try client(t)
  let job = try BulkJobReference(id: "750abc", kind: .query, apiVersion: "66.0")
  let start = ContinuousClock.now
  await #expect(throws: SalesforceError.self) {
    try await c.bulk.waitUntilComplete(job, polling: BulkPolling(interval: 1, timeout: 0.02))
  }
  #expect(start.duration(to: .now) < .seconds(1))
  #expect(await t.calls == 1)
}
@Test func storedSessionLoadsWithoutRenewal() async throws {
  let counter = Counter()
  let store = MemoryStore(SalesforceSession(accessToken: "stored", instanceURL: instance))
  let auth = SalesforceAuthentication(store: store) { _ in
    await counter.increment()
    return SalesforceSession(accessToken: "new", instanceURL: instance)
  }
  #expect(try await auth.credentials().session.accessToken == "stored")
  #expect(await counter.value == 0)
}

@Test func bulkListUsesEachJobsCreationVersionAndReferencesPersist() async throws {
  let t = FixtureTransport([
    fixture(
      "{\"done\":true,\"records\":[{\"id\":\"750old\",\"state\":\"JobComplete\",\"apiVersion\":65.0}]}"
    )
  ])
  let job = try await client(t, version: "67.0").bulk.list(.query).value.records[0].reference
  #expect(job.apiVersion == "65.0")
  let bytes = try JSONEncoder().encode(job)
  #expect(try JSONDecoder().decode(BulkJobReference.self, from: bytes) == job)
}
