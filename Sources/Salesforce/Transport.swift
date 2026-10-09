import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Single-consumer, demand-driven chunks. Dropping the stream releases its transport lease.
public struct SalesforceByteStream: AsyncSequence, Sendable {
  public typealias Element = Data
  public struct AsyncIterator: AsyncIteratorProtocol {
    let read: @Sendable () async throws -> Data?
    public mutating func next() async throws -> Data? {
      try Task.checkCancellation()
      return try await read()
    }
  }
  private let read: @Sendable () async throws -> Data?
  public init(next: @escaping @Sendable () async throws -> Data?) { read = next }
  public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(read: read) }
  public static func data(_ data: Data, chunkSize: Int = 65_536) -> Self {
    let source = DataSource(data: data, chunkSize: Swift.max(1, chunkSize))
    return Self { await source.next() }
  }
  public static func file(_ url: URL, chunkSize: Int = 65_536) throws -> Self {
    let source = try FileSource(url: url, chunkSize: Swift.max(1, chunkSize))
    return Self { try await source.next() }
  }
  public func collect(maxBytes: Int = 32 * 1024 * 1024) async throws -> Data {
    var result = Data()
    for try await chunk in self {
      guard result.count <= maxBytes - chunk.count else {
        throw SalesforceError.validation("Response exceeds collection limit; use streaming")
      }
      result.append(chunk)
    }
    return result
  }
}
private actor DataSource {
  let data: Data
  let chunkSize: Int
  var offset = 0
  init(data: Data, chunkSize: Int) {
    self.data = data
    self.chunkSize = chunkSize
  }
  func next() -> Data? {
    guard offset < data.count else { return nil }
    let end = min(data.count, offset + chunkSize)
    defer { offset = end }
    return data.subdata(in: offset..<end)
  }
}
private actor FileSource {
  let handle: FileHandle
  let chunkSize: Int
  init(url: URL, chunkSize: Int) throws {
    handle = try FileHandle(forReadingFrom: url)
    self.chunkSize = chunkSize
  }
  deinit { try? handle.close() }
  func next() throws -> Data? {
    try Task.checkCancellation()
    let data = try handle.read(upToCount: chunkSize)
    return data?.isEmpty == false ? data : nil
  }
}
public enum SalesforceRequestBody: Sendable {
  case data(Data)
  case file(URL)
  case stream(SalesforceByteStream)
  public var isReproducible: Bool {
    switch self {
    case .data, .file: true
    case .stream: false
    }
  }
}
public struct SalesforceHTTPRequest: Sendable {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: SalesforceRequestBody?
  public init(
    method: String, url: URL, headers: [String: String] = [:], body: SalesforceRequestBody? = nil
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}
public struct SalesforceHTTPResponse: Sendable {
  public let metadata: HTTPMetadata
  public let body: SalesforceByteStream
  public init(metadata: HTTPMetadata, body: SalesforceByteStream) {
    self.metadata = metadata
    self.body = body
  }
}
/// Transports must disable automatic redirects; the client validates every authenticated destination.
public protocol SalesforceTransport: Sendable {
  func execute(_ request: SalesforceHTTPRequest) async throws -> SalesforceHTTPResponse
  func shutdown() async throws
}
extension SalesforceTransport { public func shutdown() async throws {} }

/// Native async bytes on Apple platforms; a bounded delegate handoff on Linux.
public final class URLSessionTransport: SalesforceTransport, Sendable {
  private let registry = TransferRegistry()
  public init() {}
  public func execute(_ request: SalesforceHTTPRequest) async throws -> SalesforceHTTPResponse {
    try Task.checkCancellation()
    var uploadFile: URL?
    var ownsFile = false
    switch request.body {
    case .file(let url): uploadFile = url
    case .stream(let stream):
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "salesforce-upload-" + UUID().uuidString)
      guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw SalesforceError.validation("Cannot create upload spool")
      }
      ownsFile = true
      uploadFile = url
      do {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        for try await chunk in stream {
          try Task.checkCancellation()
          try file.write(contentsOf: chunk)
        }
      } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
      }
    default: break
    }
    let uploadSize: NSNumber?
    do {
      if let uploadFile {
        guard uploadFile.isFileURL else {
          throw SalesforceError.validation("Upload requires a local file URL")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: uploadFile.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
          throw SalesforceError.validation("Upload requires a regular file")
        }
        uploadSize = attributes[.size] as? NSNumber
      } else {
        uploadSize = nil
      }
    } catch {
      if ownsFile, let uploadFile { try? FileManager.default.removeItem(at: uploadFile) }
      throw error
    }
    let transfer = URLTransfer(uploadFile: ownsFile ? uploadFile : nil)
    do { try registry.add(transfer) } catch {
      if ownsFile, let uploadFile { try? FileManager.default.removeItem(at: uploadFile) }
      throw error
    }
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
    if case .data(let data) = request.body { urlRequest.httpBody = data }
    let configuration = URLSessionConfiguration.ephemeral
    #if canImport(FoundationNetworking) || SALESFORCE_FORCE_DELEGATE_TRANSPORT
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      let session = URLSession(
        configuration: configuration, delegate: transfer, delegateQueue: queue)
      let task: URLSessionTask
      if let uploadFile {
        task = session.uploadTask(with: urlRequest, fromFile: uploadFile)
      } else {
        task = session.dataTask(with: urlRequest)
      }
      transfer.start(session: session, task: task) { [registry] in registry.remove(transfer.id) }
      let metadata = try await withTaskCancellationHandler {
        try await transfer.headers()
      } onCancel: {
        transfer.cancel()
      }
      let lease = TransferLease(transfer)
      return SalesforceHTTPResponse(
        metadata: metadata,
        body: SalesforceByteStream {
          try await withTaskCancellationHandler {
            try await lease.transfer.next()
          } onCancel: {
            lease.transfer.cancel()
          }
        })
    #else
      if let uploadFile {
        urlRequest.httpBodyStream = InputStream(url: uploadFile)
        urlRequest.setValue(uploadSize?.stringValue, forHTTPHeaderField: "Content-Length")
      }
      let redirect = RejectRedirects()
      let session = URLSession(configuration: configuration, delegate: redirect, delegateQueue: nil)
      transfer.start(session: session, task: nil) { [registry] in registry.remove(transfer.id) }
      do {
        let (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirect)
        transfer.attach(bytes.task)
        guard let http = response as? HTTPURLResponse else {
          throw SalesforceError.validation("Non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
          headers[String(describing: key)] = String(describing: value)
        }
        let source = AppleByteSource(bytes, transfer: transfer)
        return SalesforceHTTPResponse(
          metadata: HTTPMetadata(status: http.statusCode, headers: headers),
          body: SalesforceByteStream { try await source.next() })
      } catch {
        transfer.cancel()
        if Task.isCancelled || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        throw error
      }
    #endif
  }

  public func shutdown() async throws { registry.shutdown() }
}
private final class TransferRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var transfers: [UUID: URLTransfer] = [:]
  private var closed = false
  func add(_ transfer: URLTransfer) throws {
    try lock.withLock {
      guard !closed else { throw SalesforceError.validation("Transport is shut down") }
      transfers[transfer.id] = transfer
    }
  }
  func remove(_ id: UUID) { _ = lock.withLock { transfers.removeValue(forKey: id) } }
  func shutdown() {
    let active = lock.withLock {
      closed = true
      let values = Array(transfers.values)
      transfers.removeAll()
      return values
    }
    for t in active { t.cancel() }
  }
}
private final class TransferLease: Sendable {
  let transfer: URLTransfer
  init(_ transfer: URLTransfer) { self.transfer = transfer }
  deinit { transfer.cancel() }
}
/// All mutable delegate state is guarded by lock. Delegate callbacks are serial; continuations resume outside the lock.
private final class URLTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let id = UUID()
  private let lock = NSCondition()
  private var session: URLSession?
  private var task: URLSessionTask?
  private var headerWaiter: CheckedContinuation<HTTPMetadata, any Error>?
  private var reader: CheckedContinuation<Data?, any Error>?
  private var metadata: HTTPMetadata?
  private var failure: (any Error)?
  private var finished = false
  private var chunks: [Data] = []
  private var buffered = 0
  private let uploadFile: URL?
  private var completion: (@Sendable () -> Void)?
  init(uploadFile: URL?) { self.uploadFile = uploadFile }
  func start(session: URLSession, task: URLSessionTask?, completion: @escaping @Sendable () -> Void)
  {
    let cancelled = lock.withLock {
      guard !finished else { return true }
      self.session = session
      self.task = task
      self.completion = completion
      return false
    }
    if cancelled {
      task?.cancel()
      session.invalidateAndCancel()
      completion()
    } else {
      task?.resume()
    }
  }
  func attach(_ task: URLSessionTask) {
    lock.withLock { if finished { task.cancel() } else { self.task = task } }
  }
  func complete() {
    end(nil)
    lock.withLock { session?.finishTasksAndInvalidate() }
  }
  func headers() async throws -> HTTPMetadata {
    try await withCheckedThrowingContinuation { c in
      let immediate: Result<HTTPMetadata, any Error>? = lock.withLock {
        if let failure { return .failure(failure) }
        if let metadata { return .success(metadata) }
        headerWaiter = c
        return nil
      }
      if let immediate { c.resume(with: immediate) }
    }
  }
  func next() async throws -> Data? {
    try await withCheckedThrowingContinuation { c in
      let result: Result<Data?, any Error>? = lock.withLock {
        if let failure { return .failure(failure) }
        if !chunks.isEmpty {
          let data = chunks.removeFirst()
          buffered -= data.count
          lock.signal()
          return .success(data)
        }
        if finished { return .success(nil) }
        guard reader == nil else {
          return .failure(SalesforceError.validation("Stream has multiple consumers"))
        }
        reader = c
        return nil
      }
      if let result { c.resume(with: result) }
    }
  }
  func cancel() {
    end(CancellationError())
    lock.withLock {
      task?.cancel()
      session?.invalidateAndCancel()
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      end(SalesforceError.validation("Non-HTTP response"))
      completionHandler(.cancel)
      return
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    let m = HTTPMetadata(status: http.statusCode, headers: headers)
    let waiter = lock.withLock {
      metadata = m
      let c = headerWaiter
      headerWaiter = nil
      return c
    }
    waiter?.resume(returning: m)
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // URLSession can deliver already queued delegate callbacks after suspend().
    // A dedicated serial delegate queue waits here until the consumer frees
    // the single buffered chunk; cancellation wakes it before invalidation.
    var offset = 0
    while offset < data.count {
      let end = min(offset + 65_536, data.count)
      let chunk = data.subdata(in: offset..<end)
      lock.lock()
      while !finished && !chunks.isEmpty { lock.wait() }
      guard !finished else {
        lock.unlock()
        return
      }
      let waiter = reader
      reader = nil
      if waiter == nil {
        chunks.append(chunk)
        buffered = chunk.count
      }
      lock.unlock()
      waiter?.resume(returning: chunk)
      offset = end
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    let normalized: (any Error)? =
      (error as? URLError)?.code == .cancelled ? CancellationError() : error
    end(normalized)
    session.finishTasksAndInvalidate()
  }
  private func end(_ error: (any Error)?) {
    let state = lock.withLock {
      () -> (
        CheckedContinuation<HTTPMetadata, any Error>?, CheckedContinuation<Data?, any Error>?,
        (@Sendable () -> Void)?
      ) in
      guard !finished else { return (nil, nil, nil) }
      finished = true
      failure = error
      lock.broadcast()
      let h = headerWaiter
      headerWaiter = nil
      let r = reader
      reader = nil
      let done = completion
      completion = nil
      return (h, r, done)
    }
    state.0?.resume(throwing: error ?? SalesforceError.validation("Missing response headers"))
    if let error { state.1?.resume(throwing: error) } else { state.1?.resume(returning: nil) }
    if let uploadFile { try? FileManager.default.removeItem(at: uploadFile) }
    state.2?()
  }
}

#if !canImport(FoundationNetworking) && !SALESFORCE_FORCE_DELEGATE_TRANSPORT
  private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
  }
  /// The lock grants exclusive iterator ownership throughout each asynchronous read.
  private final class AppleByteSource: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: URLSession.AsyncBytes.Iterator
    private var reading = false
    private var ended = false
    private let transfer: URLTransfer
    init(_ bytes: URLSession.AsyncBytes, transfer: URLTransfer) {
      iterator = bytes.makeAsyncIterator()
      self.transfer = transfer
    }
    deinit { transfer.cancel() }
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
      if lock.withLock({ ended }) { return nil }
      return try await withTaskCancellationHandler {
        do {
          var chunk = Data()
          chunk.reserveCapacity(65_536)
          while chunk.count < 65_536 {
            guard let byte = try await current.next() else {
              lock.withLock { ended = true }
              transfer.complete()
              return chunk.isEmpty ? nil : chunk
            }
            chunk.append(byte)
          }
          return chunk
        } catch {
          transfer.cancel()
          if Task.isCancelled || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
          }
          throw error
        }
      } onCancel: {
        transfer.cancel()
      }
    }
  }
#endif
