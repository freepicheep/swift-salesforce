import Foundation
import Salesforce
import SalesforceAsyncHTTPClient
import Testing

#if os(macOS) || os(Linux)
  private final class LocalServer {
    let process: Process
    let url: URL
    init() throws {
      let p = Process()
      let pipe = Pipe()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("server.py")
      p.arguments = ["python3", "-u", script.path]
      p.standardOutput = pipe
      try p.run()
      var line = Data()
      while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
        if byte[0] == 10 { break }
        line.append(byte)
      }
      guard let port = Int(String(decoding: line, as: UTF8.self)) else {
        p.terminate()
        throw SalesforceError.validation("Local server did not start")
      }
      process = p
      url = URL(string: "http://127.0.0.1:\(port)")!
    }
    deinit {
      process.terminate()
      process.waitUntilExit()
    }
  }
  @Suite(.serialized) struct TransportTests {
    @Test func realHTTPStreamingUploadsRedirectsAndCancellation() async throws {
      let server = try LocalServer()
      let factories: [@Sendable () -> any SalesforceTransport] = [
        { URLSessionTransport() }, { AsyncHTTPClientTransport() },
      ]
      for factory in factories {
        let transport = factory()
        func trace(_ message: String) {
          FileHandle.standardError.write(
            Data("Transport \(type(of: transport)): \(message)\n".utf8))
        }
        trace("starting")
        do {
          let basic = try await transport.execute(
            SalesforceHTTPRequest(method: "GET", url: server.url.appendingPathComponent("small")))
          #expect(try await basic.body.collect().count == 16)
          #expect(basic.metadata.apiLimits["api-usage"]?.used == 1)
          trace("basic passed")
          let large = try await transport.execute(
            SalesforceHTTPRequest(method: "GET", url: server.url.appendingPathComponent("large")))
          var total = 0
          var largest = 0
          for try await chunk in large.body {
            total += chunk.count
            largest = max(largest, chunk.count)
            try await Task.sleep(for: .milliseconds(1))
          }
          #expect(total == 8 * 1024 * 1024)
          #expect(largest <= 2 * 1024 * 1024)
          trace("large passed")
          let redirect = try await transport.execute(
            SalesforceHTTPRequest(
              method: "GET", url: server.url.appendingPathComponent("redirect"),
              headers: ["Authorization": "Bearer secret"]))
          #expect(redirect.metadata.status == 302)
          _ = try await redirect.body.collect()
          trace("redirect passed")
          let body = Data(repeating: 120, count: 256 * 1024)
          let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
          try body.write(to: file)
          defer { try? FileManager.default.removeItem(at: file) }
          for upload in [
            SalesforceRequestBody.data(body), .file(file), .stream(.data(body, chunkSize: 1024)),
          ] {
            let response = try await transport.execute(
              SalesforceHTTPRequest(
                method: "PUT", url: server.url.appendingPathComponent("upload"), body: upload))
            #expect(try await response.body.collect() == Data(String(body.count).utf8))
          }
          trace("uploads passed")
          await #expect(throws: (any Error).self) {
            let broken = try await transport.execute(
              SalesforceHTTPRequest(method: "GET", url: server.url.appendingPathComponent("broken"))
            )
            _ = try await broken.body.collect()
          }
          trace("interrupted transfer passed")
          let slowURL = server.url.appendingPathComponent("slow")
          let task = Task {
            try await transport.execute(SalesforceHTTPRequest(method: "GET", url: slowURL))
          }
          try await Task.sleep(for: .milliseconds(50))
          task.cancel()
          await #expect(throws: CancellationError.self) { try await task.value }
          trace("cancellation passed")
          try await transport.shutdown()
        } catch {
          trace("failed: \(error)")
          try? await transport.shutdown()
          throw error
        }
      }
    }
    @Test func uploadSpoolCleanupOnSuccessFailureAndCancellation() async throws {
      let server = try LocalServer()
      let transport = URLSessionTransport()
      func spools() throws -> Set<String> {
        Set(
          try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
          ).filter { $0.hasPrefix("salesforce-upload-") })
      }
      let before = try spools()
      do {
        let response = try await transport.execute(
          SalesforceHTTPRequest(
            method: "PUT", url: server.url.appendingPathComponent("upload"),
            body: .stream(.data(Data(repeating: 120, count: 100_000)))))
        _ = try await response.body.collect()
        #expect(try spools() == before)
        let failing = UploadSource(fail: true)
        await #expect(throws: SalesforceError.self) {
          try await transport.execute(
            SalesforceHTTPRequest(
              method: "PUT", url: server.url.appendingPathComponent("upload"),
              body: .stream(SalesforceByteStream { try await failing.next() })))
        }
        #expect(try spools() == before)
        let delayed = UploadSource(fail: false)
        let url = server.url.appendingPathComponent("upload")
        let task = Task {
          try await transport.execute(
            SalesforceHTTPRequest(
              method: "PUT", url: url,
              body: .stream(SalesforceByteStream { try await delayed.next() })))
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try spools() == before)
        try await transport.shutdown()
      } catch {
        try? await transport.shutdown()
        throw error
      }
    }
    @Test func collectionLimitAndOwnedShutdown() async throws {
      await #expect(throws: SalesforceError.self) {
        try await SalesforceByteStream.data(Data(repeating: 0, count: 100)).collect(maxBytes: 10)
      }
      let transport = URLSessionTransport()
      try await transport.shutdown()
      await #expect(throws: SalesforceError.self) {
        try await transport.execute(
          SalesforceHTTPRequest(method: "GET", url: URL(string: "http://127.0.0.1")!))
      }
    }
  }
#endif

private actor UploadSource {
  let fail: Bool
  var started = false
  init(fail: Bool) { self.fail = fail }
  func next() async throws -> Data? {
    if !started {
      started = true
      return Data(repeating: 120, count: 4096)
    }
    if fail { throw SalesforceError.validation("Source failure") }
    try await Task.sleep(for: .seconds(10))
    return nil
  }
}
