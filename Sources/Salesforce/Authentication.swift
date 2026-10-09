import Crypto
import CryptoExtras
import Foundation

public struct SalesforceSession: Codable, Sendable, Equatable {
  public let accessToken: String
  public let instanceURL: URL
  public let refreshToken: String?
  public let expiresAt: Date?
  public init(
    accessToken: String, instanceURL: URL, refreshToken: String? = nil, expiresAt: Date? = nil
  ) {
    self.accessToken = accessToken
    self.instanceURL = instanceURL
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }
}
public struct SalesforceCredentials: Sendable {
  public let session: SalesforceSession
  public let generation: UInt64
  public init(session: SalesforceSession, generation: UInt64 = 0) {
    self.session = session
    self.generation = generation
  }
}
public protocol SalesforceTokenProvider: Sendable {
  func credentials() async throws -> SalesforceCredentials
  func renew(invalidating generation: UInt64) async throws -> SalesforceCredentials
}
public struct AccessTokenProvider: SalesforceTokenProvider {
  private let session: SalesforceSession
  public init(_ session: SalesforceSession) { self.session = session }
  public func credentials() async throws -> SalesforceCredentials {
    SalesforceCredentials(session: session)
  }
  public func renew(invalidating generation: UInt64) async throws -> SalesforceCredentials {
    throw SalesforceError.authentication("Access token expired; supply a renewable token provider")
  }
}
public protocol SalesforceTokenStore: Sendable {
  func load() async throws -> SalesforceSession?
  func save(_ session: SalesforceSession) async throws
}
/// Cancellation of an individual waiter never cancels the shared renewal task.
public actor SalesforceAuthentication: SalesforceTokenProvider {
  public typealias Renewal = @Sendable (SalesforceSession?) async throws -> SalesforceSession
  private var session: SalesforceSession?
  private var generation: UInt64 = 0
  private var pending: Task<SalesforceCredentials, any Error>?
  private var loaded = false
  private let store: (any SalesforceTokenStore)?
  private let renewal: Renewal
  public init(
    session: SalesforceSession? = nil, store: (any SalesforceTokenStore)? = nil,
    renewal: @escaping Renewal
  ) {
    self.session = session
    self.store = store
    self.renewal = renewal
  }
  public func credentials() async throws -> SalesforceCredentials {
    try Task.checkCancellation()
    if let pending {
      let value = try await pending.value
      try Task.checkCancellation()
      return value
    }
    if loaded || store == nil, let session,
      session.expiresAt.map({ $0.timeIntervalSinceNow > 30 }) ?? true
    {
      return SalesforceCredentials(session: session, generation: generation)
    }
    return try await sharedRenewal(force: false)
  }
  public func renew(invalidating invalidGeneration: UInt64) async throws -> SalesforceCredentials {
    try Task.checkCancellation()
    if invalidGeneration != generation, let session {
      return SalesforceCredentials(session: session, generation: generation)
    }
    return try await sharedRenewal(force: true)
  }
  public func currentSession() -> SalesforceSession? { session }
  private func sharedRenewal(force: Bool) async throws -> SalesforceCredentials {
    if pending == nil {
      pending = Task { try await self.performRenewal(force: force) }
    }
    let value = try await pending!.value
    try Task.checkCancellation()
    return value
  }
  private func performRenewal(force: Bool) async throws -> SalesforceCredentials {
    defer { pending = nil }
    if !loaded {
      loaded = true
      if session == nil, let store {
        do { session = try await store.load() } catch {
          loaded = false
          throw SalesforceError.tokenStorage(String(describing: error))
        }
      }
    }
    if !force, let session, session.expiresAt.map({ $0.timeIntervalSinceNow > 30 }) ?? true {
      return SalesforceCredentials(session: session, generation: generation)
    }
    let fresh = try await renewal(session)
    session = fresh
    generation &+= 1
    if let store {
      do { try await store.save(fresh) } catch {
        throw SalesforceError.tokenStorage(String(describing: error))
      }
    }
    return SalesforceCredentials(session: fresh, generation: generation)
  }
}
public enum SalesforceLoginDomain: Sendable {
  case production, sandbox
  case custom(URL)
  public var url: URL {
    switch self {
    case .production: URL(string: "https://login.salesforce.com")!
    case .sandbox: URL(string: "https://test.salesforce.com")!
    case .custom(let u): u
    }
  }
}
public struct SalesforceAuthorization: Sendable {
  public let url: URL
  public let state: String
  public let verifier: String
  public let redirectURI: URL
}
public struct SalesforceOAuth: Sendable {
  public let clientID: String
  public let domain: SalesforceLoginDomain
  private let transport: any SalesforceTransport
  public init(
    clientID: String, domain: SalesforceLoginDomain = .production,
    transport: any SalesforceTransport = URLSessionTransport()
  ) {
    self.clientID = clientID
    self.domain = domain
    self.transport = transport
  }
  public func authorization(redirectURI: URL, scopes: [String] = ["api", "refresh_token"]) throws
    -> SalesforceAuthorization
  {
    try validateLogin()
    let verifier = randomToken()
    let state = randomToken()
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    var components = URLComponents(
      url: domain.url.appendingPathComponent("services/oauth2/authorize"),
      resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
      URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return SalesforceAuthorization(
      url: components.url!, state: state, verifier: verifier, redirectURI: redirectURI)
  }
  public func exchange(
    callback: URL, authorization: SalesforceAuthorization, clientSecret: String? = nil
  ) async throws -> SalesforceSession {
    guard callback.scheme == authorization.redirectURI.scheme,
      callback.host == authorization.redirectURI.host,
      callback.port == authorization.redirectURI.port,
      callback.path == authorization.redirectURI.path
    else { throw SalesforceError.authentication("OAuth callback destination mismatch") }
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func unique(_ name: String) -> String? {
      let matches = items.filter { $0.name == name }
      return matches.count == 1 ? matches[0].value : nil
    }
    guard let state = unique("state"), constantTimeEqual(state, authorization.state) else {
      throw SalesforceError.authentication("OAuth state mismatch")
    }
    if let error = unique("error") { throw SalesforceError.authentication(error) }
    guard let code = unique("code"), !code.isEmpty else {
      throw SalesforceError.authentication("Missing authorization code")
    }
    var fields = [
      "grant_type": "authorization_code", "code": code,
      "redirect_uri": authorization.redirectURI.absoluteString,
      "code_verifier": authorization.verifier,
    ]
    fields["client_secret"] = clientSecret
    return try await token(fields)
  }
  public func refresh(_ session: SalesforceSession, clientSecret: String? = nil) async throws
    -> SalesforceSession
  {
    guard let refresh = session.refreshToken else {
      throw SalesforceError.authentication("No refresh token")
    }
    var fields = ["grant_type": "refresh_token", "refresh_token": refresh]
    fields["client_secret"] = clientSecret
    return try await token(fields, previous: session)
  }
  public func clientCredentials(clientSecret: String) async throws -> SalesforceSession {
    try await token(["grant_type": "client_credentials", "client_secret": clientSecret])
  }
  @concurrent public func jwtBearer(
    username: String, privateKeyPEM: String, lifetime: TimeInterval = 180
  ) async throws -> SalesforceSession {
    guard lifetime > 0, lifetime <= 180 else {
      throw SalesforceError.validation("JWT lifetime must be within 180 seconds")
    }
    let header = Data("{\"alg\":\"RS256\",\"typ\":\"JWT\"}".utf8).base64URL
    let claims: JSONValue = .object([
      "iss": .string(clientID), "sub": .string(username), "aud": .string(domain.url.absoluteString),
      "exp": .number(Decimal(Int(Date().timeIntervalSince1970 + lifetime))),
    ])
    let payload = try JSONEncoder().encode(claims).base64URL
    let input = "\(header).\(payload)"
    let key = try _RSA.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    let signature = try key.signature(for: Data(input.utf8), padding: .insecurePKCS1v1_5)
      .rawRepresentation.base64URL
    return try await token([
      "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
      "assertion": "\(input).\(signature)",
    ])
  }
  private func validateLogin() throws {
    let u = domain.url
    guard u.scheme == "https", u.host != nil, u.user == nil, u.password == nil, u.query == nil,
      u.fragment == nil, u.path.isEmpty || u.path == "/"
    else { throw SalesforceError.validation("Login domain must be an HTTPS origin") }
  }
  private func token(_ fields: [String: String], previous: SalesforceSession? = nil) async throws
    -> SalesforceSession
  {
    try validateLogin()
    try Task.checkCancellation()
    var fields = fields
    fields["client_id"] = clientID
    let body = fields.sorted(by: { $0.key < $1.key }).map {
      "\(pathComponent($0.key))=\(pathComponent($0.value))"
    }.joined(separator: "&")
    let response = try await transport.execute(
      SalesforceHTTPRequest(
        method: "POST", url: domain.url.appendingPathComponent("services/oauth2/token"),
        headers: ["Content-Type": "application/x-www-form-urlencoded"], body: .data(Data(body.utf8))
      ))
    let data = try await response.body.collect(maxBytes: 1024 * 1024)
    guard (200..<300).contains(response.metadata.status) else {
      throw SalesforceError.http(status: response.metadata.status, body: data)
    }
    struct Token: Decodable {
      let access_token: String
      let instance_url: URL
      let refresh_token: String?
      let expires_in: Int?
    }
    let decoded: Token
    do { decoded = try JSONDecoder().decode(Token.self, from: data) } catch {
      throw SalesforceError.decoding(String(describing: error))
    }
    guard decoded.instance_url.scheme == "https", decoded.instance_url.host != nil,
      decoded.instance_url.user == nil, decoded.instance_url.password == nil,
      decoded.instance_url.query == nil, decoded.instance_url.fragment == nil,
      decoded.instance_url.path.isEmpty || decoded.instance_url.path == "/"
    else { throw SalesforceError.authentication("Invalid instance URL") }
    return SalesforceSession(
      accessToken: decoded.access_token, instanceURL: decoded.instance_url,
      refreshToken: decoded.refresh_token ?? previous?.refreshToken,
      expiresAt: decoded.expires_in.map { Date().addingTimeInterval(Double($0)) })
  }
}
private func randomToken() -> String {
  var rng = SystemRandomNumberGenerator()
  return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }).base64URL
}
private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
  let a = Array(a.utf8)
  let b = Array(b.utf8)
  guard a.count == b.count else { return false }
  return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
extension Data {
  fileprivate var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
}
