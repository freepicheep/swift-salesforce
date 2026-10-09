import Foundation
import Hummingbird
import Salesforce
import SalesforceAsyncHTTPClient

@main struct Server {
  static func main() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let id = env["SALESFORCE_CLIENT_ID"], let secret = env["SALESFORCE_CLIENT_SECRET"],
      let version = env["SALESFORCE_API_VERSION"],
      let domain = env["SALESFORCE_LOGIN_URL"].flatMap(URL.init(string:))
    else {
      throw SalesforceError.validation(
        "Set SALESFORCE_CLIENT_ID, SALESFORCE_CLIENT_SECRET, SALESFORCE_LOGIN_URL and SALESFORCE_API_VERSION"
      )
    }
    let transport = AsyncHTTPClientTransport()
    let oauth = SalesforceOAuth(clientID: id, domain: .custom(domain), transport: transport)
    let auth = SalesforceAuthentication { _ in
      try await oauth.clientCredentials(clientSecret: secret)
    }
    let client = SalesforceClient(
      configuration: try SalesforceConfiguration(apiVersion: version), tokenProvider: auth,
      transport: transport)
    let router = Router()
    router.get("/accounts") { _, _ -> String in
      let response = try await client.queries.page(
        "SELECT Id, Name FROM Account LIMIT 100", as: SalesforceRecord.self)
      return String(decoding: try JSONEncoder().encode(response.value.records), as: UTF8.self)
    }
    let application = Application(
      router: router, configuration: .init(address: .hostname("127.0.0.1", port: 8080)))
    do {
      try await application.runService()
      try await transport.shutdown()
    } catch {
      try? await transport.shutdown()
      throw error
    }
  }
}
