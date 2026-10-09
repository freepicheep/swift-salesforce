import Foundation

public struct SalesforceConfiguration: Sendable {
  public let apiVersion: String
  public var retry: RetryPolicy
  public var codecs: SalesforceCodecs
  /// For offline loopback tests only. Production credentials always require HTTPS.
  public var allowInsecureHTTP: Bool
  public var maxJSONBytes: Int
  public var observer: (@Sendable (RequestObservation) -> Void)?
  public init(
    apiVersion: String, retry: RetryPolicy = RetryPolicy(),
    codecs: SalesforceCodecs = SalesforceCodecs(), allowInsecureHTTP: Bool = false,
    maxJSONBytes: Int = 32 * 1024 * 1024, observer: (@Sendable (RequestObservation) -> Void)? = nil
  ) throws {
    let parts = apiVersion.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
      let major = Int(parts[0]), major > 0, maxJSONBytes > 0
    else { throw SalesforceError.validation("Explicit numeric API version required, e.g. 66.0") }
    self.apiVersion = apiVersion
    self.retry = retry
    self.codecs = codecs
    self.allowInsecureHTTP = allowInsecureHTTP
    self.maxJSONBytes = maxJSONBytes
    self.observer = observer
  }
}
public struct RetryPolicy: Sendable {
  public let maxAttempts: Int
  public let baseDelay: TimeInterval
  public let maxDelay: TimeInterval
  public let jitter: Bool
  public init(
    maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 30,
    jitter: Bool = true
  ) {
    self.maxAttempts = max(1, maxAttempts)
    self.baseDelay = baseDelay.isFinite ? max(0, baseDelay) : 0
    self.maxDelay = maxDelay.isFinite ? max(0, maxDelay) : 30
    self.jitter = jitter
  }
}
public struct RequestObservation: Sendable {
  public let method: String
  public let path: String
  public let duration: TimeInterval
  public let metadata: HTTPMetadata?
}
public struct SalesforceClient: Sendable {
  public let configuration: SalesforceConfiguration
  public let tokenProvider: any SalesforceTokenProvider
  public let transport: any SalesforceTransport
  private let ownsTransport: Bool
  public init(
    configuration: SalesforceConfiguration, tokenProvider: any SalesforceTokenProvider,
    transport: (any SalesforceTransport)? = nil
  ) {
    self.configuration = configuration
    self.tokenProvider = tokenProvider
    self.transport = transport ?? URLSessionTransport()
    ownsTransport = transport == nil
  }
  public func shutdown() async throws { if ownsTransport { try await transport.shutdown() } }
  public var dataPath: String { "/services/data/v\(configuration.apiVersion)" }
  public var records: SalesforceRecords { SalesforceRecords(client: self) }
  public var queries: SalesforceQueries { SalesforceQueries(client: self) }
  public var search: SalesforceSearch { SalesforceSearch(client: self) }
  public var composite: SalesforceComposite { SalesforceComposite(client: self) }
  public var bulk: SalesforceBulk { SalesforceBulk(client: self) }
  public func versions() async throws -> SalesforceResponse<[APIVersion]> {
    try await request("GET", path: "/services/data/", as: [APIVersion].self)
  }
  public func resources() async throws -> SalesforceResponse<SalesforceRecord> {
    try await request("GET", path: dataPath + "/", as: SalesforceRecord.self)
  }
  public func objects() async throws -> SalesforceResponse<SalesforceRecord> {
    try await request("GET", path: dataPath + "/sobjects", as: SalesforceRecord.self)
  }
  public func describe(_ object: String) async throws -> SalesforceResponse<SalesforceRecord> {
    try validateIdentifier(object)
    return try await request(
      "GET", path: dataPath + "/sobjects/\(object)/describe", as: SalesforceRecord.self)
  }
  public func limits() async throws -> SalesforceResponse<SalesforceRecord> {
    try await request("GET", path: dataPath + "/limits", as: SalesforceRecord.self)
  }
  public func request<T: Decodable & Sendable>(
    _ method: String, path: String, query: [URLQueryItem] = [], body: SalesforceRequestBody? = nil,
    headers: [String: String] = [:], as type: T.Type
  ) async throws -> SalesforceResponse<T> {
    let response = try await stream(method, path: path, query: query, body: body, headers: headers)
    let data = try await response.body.collect(maxBytes: configuration.maxJSONBytes)
    let value: T
    if type == EmptyResponse.self, data.isEmpty {
      value = EmptyResponse() as! T
    } else {
      value = try await configuration.codecs.decode(type, from: data)
    }
    return SalesforceResponse(value: value, metadata: response.metadata)
  }
  public func request<Payload: Encodable & Sendable, Value: Decodable & Sendable>(
    _ method: String, path: String, query: [URLQueryItem] = [], payload: Payload,
    as type: Value.Type
  ) async throws -> SalesforceResponse<Value> {
    try await request(
      method, path: path, query: query, body: .data(configuration.codecs.encode(payload)), as: type)
  }
  public func stream(
    _ method: String, path: String, query: [URLQueryItem] = [], body: SalesforceRequestBody? = nil,
    headers: [String: String] = [:]
  ) async throws -> SalesforceHTTPResponse {
    let method = method.uppercased()
    let read = method == "GET" || method == "HEAD"
    var credentials = try await tokenProvider.credentials()
    var renewed = false
    var attempt = 1
    while true {
      try Task.checkCancellation()
      let url = try destination(path, query: query, instance: credentials.session.instanceURL)
      var h = headers
      for key in h.keys where ["authorization", "host", "cookie"].contains(key.lowercased()) {
        h.removeValue(forKey: key)
      }
      h["Authorization"] = "Bearer \(credentials.session.accessToken)"
      if !h.keys.contains(where: { $0.lowercased() == "accept" }) {
        h["Accept"] = "application/json"
      }
      if body != nil, !h.keys.contains(where: { $0.lowercased() == "content-type" }) {
        h["Content-Type"] = "application/json"
      }
      let started = Date()
      let response: SalesforceHTTPResponse
      do {
        response = try await transport.execute(
          SalesforceHTTPRequest(method: method, url: url, headers: h, body: body))
      } catch {
        configuration.observer?(
          RequestObservation(
            method: method, path: url.path, duration: Date().timeIntervalSince(started),
            metadata: nil))
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        guard read, attempt < configuration.retry.maxAttempts, isTransient(error) else {
          throw error
        }
        try await delay(attempt: attempt, retryAfter: nil)
        attempt += 1
        continue
      }
      configuration.observer?(
        RequestObservation(
          method: method, path: url.path, duration: Date().timeIntervalSince(started),
          metadata: response.metadata))
      if (200..<300).contains(response.metadata.status) { return response }
      let data = try await response.body.collect(maxBytes: configuration.maxJSONBytes)
      let errors = try? JSONDecoder().decode([APIError].self, from: data)
      if response.metadata.status == 401,
        errors?.contains(where: { $0.errorCode == "INVALID_SESSION_ID" }) == true, !renewed,
        body?.isReproducible ?? true
      {
        credentials = try await tokenProvider.renew(invalidating: credentials.generation)
        renewed = true
        continue
      }
      if read, attempt < configuration.retry.maxAttempts,
        [408, 429, 500, 502, 503, 504].contains(response.metadata.status)
      {
        try await delay(attempt: attempt, retryAfter: response.metadata.header("Retry-After"))
        attempt += 1
        continue
      }
      if let errors {
        throw SalesforceError.salesforce(status: response.metadata.status, errors: errors)
      }
      throw SalesforceError.http(status: response.metadata.status, body: data)
    }
  }
  private func destination(_ path: String, query: [URLQueryItem], instance: URL) throws -> URL {
    guard
      instance.scheme == "https"
        || (configuration.allowInsecureHTTP && instance.scheme == "http"
          && ["localhost", "127.0.0.1", "::1"].contains(instance.host ?? "")),
      instance.host != nil, instance.user == nil, instance.password == nil, instance.query == nil,
      instance.fragment == nil, instance.path.isEmpty || instance.path == "/"
    else { throw SalesforceError.validation("Instance URL must be a trusted HTTPS origin") }
    guard !path.contains("\\"), let url = URL(string: path, relativeTo: instance)?.absoluteURL,
      url.scheme == instance.scheme, url.host?.lowercased() == instance.host?.lowercased(),
      url.port == instance.port, url.user == nil, url.password == nil, url.fragment == nil
    else { throw SalesforceError.validation("Untrusted continuation destination") }
    let decoded = url.path.removingPercentEncoding ?? url.path
    guard decoded == "/services/data" || decoded.hasPrefix("/services/data/"),
      !decoded.split(separator: "/").contains(".."), !decoded.contains("\\")
    else { throw SalesforceError.validation("API path must remain under /services/data/") }
    guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SalesforceError.validation("Invalid URL")
    }
    if !query.isEmpty { c.queryItems = (c.queryItems ?? []) + query }
    guard let result = c.url else { throw SalesforceError.validation("Invalid query") }
    return result
  }
  private func delay(attempt: Int, retryAfter: String?) async throws {
    var seconds = min(
      configuration.retry.maxDelay,
      configuration.retry.baseDelay * pow(2, Double(min(attempt - 1, 20))))
    if configuration.retry.jitter { seconds *= Double.random(in: 0.5...1) }
    if let retryAfter {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = TimeZone(secondsFromGMT: 0)
      f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      if let n = Double(retryAfter), n.isFinite {
        seconds = max(seconds, min(configuration.retry.maxDelay, max(0, n)))
      } else if let date = f.date(from: retryAfter) {
        seconds = max(seconds, min(configuration.retry.maxDelay, max(0, date.timeIntervalSinceNow)))
      }
    }
    try await Task.sleep(for: .seconds(seconds))
  }
}
private func isTransient(_ error: any Error) -> Bool {
  guard let error = error as? URLError else { return false }
  return [
    .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
    .notConnectedToInternet,
  ].contains(error.code)
}
public struct APIVersion: Codable, Sendable {
  public let label: String
  public let url: String
  public let version: String
}
