import Crypto
import CryptoExtras
import Foundation
import Salesforce
import Testing

@Test func jwtRS256SignatureAndClientCredentials() async throws {
  let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
  let t = FixtureTransport([
    fixture("{\"access_token\":\"jwt\",\"instance_url\":\"https://org.my.salesforce.com\"}"),
    fixture("{\"access_token\":\"cc\",\"instance_url\":\"https://org.my.salesforce.com\"}"),
  ])
  let oauth = SalesforceOAuth(clientID: "client", domain: .sandbox, transport: t)
  #expect(
    try await oauth.jwtBearer(username: "user@example.com", privateKeyPEM: key.pemRepresentation)
      .accessToken == "jwt")
  #expect(try await oauth.clientCredentials(clientSecret: "a+b&c").accessToken == "cc")
  let requests = await t.requests
  guard case .data(let body) = requests[0].body else {
    Issue.record("Missing JWT grant")
    return
  }
  let pairs = String(decoding: body, as: UTF8.self).split(separator: "&").map {
    $0.split(separator: "=", maxSplits: 1)
  }
  let assertion = pairs.first { $0[0] == "assertion" }![1].removingPercentEncoding!
  let parts = assertion.split(separator: ".")
  func decode(_ s: Substring) -> Data {
    var text = String(s).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    while text.count % 4 != 0 { text += "=" }
    return Data(base64Encoded: text)!
  }
  let signature = _RSA.Signing.RSASignature(rawRepresentation: decode(parts[2]))
  #expect(
    key.publicKey.isValidSignature(
      signature, for: Data("\(parts[0]).\(parts[1])".utf8), padding: .insecurePKCS1v1_5))
  let payload = try JSONDecoder().decode(SalesforceRecord.self, from: decode(parts[1]))
  #expect(payload["aud"] == .string("https://test.salesforce.com"))
  #expect(payload["sub"] == .string("user@example.com"))
  guard case .data(let credentialsBody) = requests[1].body else {
    Issue.record("Missing client credentials body")
    return
  }
  #expect(String(decoding: credentialsBody, as: UTF8.self).contains("client_secret=a%2Bb%26c"))
}
