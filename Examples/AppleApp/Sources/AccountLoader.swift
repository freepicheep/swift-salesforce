import Foundation
import Salesforce

public struct Account: Codable, Sendable {
  public let Id: String
  public let Name: String
}
/// An app retains the authorization transaction while presenting its URL using ASWebAuthenticationSession.
/// Route its callback URL to finishSignIn; browser presentation and Keychain storage remain app responsibilities.
@MainActor public final class AccountLoader {
  private let oauth: SalesforceOAuth
  private let version: String
  private var client: SalesforceClient?
  public private(set) var accounts: [Account] = []
  public init(clientID: String, apiVersion: String, domain: SalesforceLoginDomain = .production) {
    oauth = SalesforceOAuth(clientID: clientID, domain: domain)
    version = apiVersion
  }
  public func beginSignIn(redirectURI: URL) throws -> SalesforceAuthorization {
    try oauth.authorization(redirectURI: redirectURI)
  }
  public func finishSignIn(
    callback: URL, transaction: SalesforceAuthorization, store: (any SalesforceTokenStore)? = nil
  ) async throws {
    let session = try await oauth.exchange(callback: callback, authorization: transaction)
    if let store { try await store.save(session) }
    let oauth = oauth
    let auth = SalesforceAuthentication(session: session, store: store) { session in
      guard let session else { throw SalesforceError.authentication("Sign in first") }
      return try await oauth.refresh(session)
    }
    client = SalesforceClient(
      configuration: try SalesforceConfiguration(apiVersion: version), tokenProvider: auth)
  }
  public func loadAccounts() async throws {
    guard let client else { throw SalesforceError.authentication("Sign in first") }
    var loaded: [Account] = []
    for try await account in client.queries.records(
      "SELECT Id, Name FROM Account LIMIT 100", as: Account.self)
    { loaded.append(account) }
    accounts = loaded
  }
  public func shutdown() async throws { try await client?.shutdown() }
}
