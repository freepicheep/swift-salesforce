import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Salesforce

public final class AsyncHTTPClientTransport: SalesforceTransport, Sendable {
  private let client: HTTPClient
  private let owned: Bool
  public let timeout: TimeInterval
  public init(timeout: TimeInterval = 60) {
    client = HTTPClient(
      eventLoopGroupProvider: .singleton, configuration: .init(redirectConfiguration: .disallow))
    owned = true
    self.timeout =
      timeout.isFinite && timeout > 0 && timeout < Double(Int64.max) / 1000 ? timeout : 60
  }
  /// The supplied HTTPClient MUST use redirectConfiguration: .disallow. Its owner handles shutdown.
  public init(clientWithRedirectsDisabled client: HTTPClient, timeout: TimeInterval = 60) {
    self.client = client
    owned = false
    self.timeout =
      timeout.isFinite && timeout > 0 && timeout < Double(Int64.max) / 1000 ? timeout : 60
  }
  public func execute(_ request: SalesforceHTTPRequest) async throws -> SalesforceHTTPResponse {
    var r = HTTPClientRequest(url: request.url.absoluteString)
    r.method = HTTPMethod(rawValue: request.method)
    for (key, value) in request.headers { r.headers.add(name: key, value: value) }
    switch request.body {
    case .data(let data): r.body = .bytes(data)
    case .file(let url):
      let stream = try SalesforceByteStream.file(url)
      let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
      r.body = .stream(
        stream.map { ByteBuffer(bytes: $0) }, length: size.map { .known($0.int64Value) } ?? .unknown
      )
    case .stream(let stream):
      r.body = .stream(stream.map { ByteBuffer(bytes: $0) }, length: .unknown)
    case nil: break
    }
    let response: HTTPClientResponse
    do {
      response = try await client.execute(r, timeout: .milliseconds(Int64(max(1, timeout * 1000))))
    } catch { throw normalized(error) }
    var headers: [String: String] = [:]
    for (key, value) in response.headers { headers[key] = value }
    let source = ResponseSource(response.body)
    return SalesforceHTTPResponse(
      metadata: HTTPMetadata(status: Int(response.status.code), headers: headers),
      body: SalesforceByteStream { try await source.next() })
  }
  public func shutdown() async throws { if owned { try await client.shutdown() } }
}
// AsyncHTTPClient's iterator is deliberately non-Sendable. The lock grants one reader
// exclusive ownership until its await finishes; no other call touches the iterator.
private final class ResponseSource: @unchecked Sendable {
  private let lock = NSLock()
  private var iterator: HTTPClientResponse.Body.AsyncIterator
  private var reading = false
  init(_ body: HTTPClientResponse.Body) { iterator = body.makeAsyncIterator() }
  @concurrent func next() async throws -> Data? {
    var current = try lock.withLock {
      guard !reading else { throw SalesforceError.validation("Stream has multiple consumers") }
      reading = true
      return iterator
    }
    defer {
      lock.withLock {
        iterator = current
        reading = false
      }
    }
    do {
      let bytes = try await current.next()
      return bytes.map { Data($0.readableBytesView) }
    } catch { throw normalized(error) }
  }
}

private func normalized(_ error: any Error) -> any Error {
  if Task.isCancelled || error as? HTTPClientError == .cancelled { return CancellationError() }
  if let http = error as? HTTPClientError {
    if [
      .readTimeout, .writeTimeout, .connectTimeout, .deadlineExceeded,
      .getConnectionFromPoolTimeout,
    ].contains(http) {
      return URLError(.timedOut)
    }
    if http == .remoteConnectionClosed { return URLError(.networkConnectionLost) }
  }
  return error
}
