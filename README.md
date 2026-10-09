# swift-salesforce

A Swift 6.4 client for Salesforce REST data APIs and Bulk API 2.0. Supports macOS 13+, iOS 16+, and Linux. Authentication and HTTP transports are injectable; the client is an immutable `Sendable` value.

Add this repository as a Swift package dependency. Import `Salesforce` for the default URLSession transport. Server applications can also depend on `SalesforceAsyncHTTPClient` for a pooled, streaming transport.

```swift
import Salesforce

struct Account: Decodable, Sendable {
    let Id: String
    let Name: String
}

let session = SalesforceSession(
    accessToken: accessToken,
    instanceURL: instanceURL
)
let client = SalesforceClient(
    configuration: try SalesforceConfiguration(apiVersion: "66.0"),
    tokenProvider: AccessTokenProvider(session)
)
for try await account in client.queries.records(
    "SELECT Id, Name FROM Account", as: Account.self
) {
    print(account.Name)
}
try await client.shutdown()
```

The API version is explicitly supplied by the caller; choose a version supported by your org. Query pages load on demand. All operations are async and preserve cancellation.

Dynamic records preserve decimal JSON numbers. Assign `.null` to clear a Salesforce field; remove a key to omit it:

```swift
let fields = SalesforceRecord([
    "Name": .string("Example"),
    "Description": .null
])
let result = try await client.records.create("Account", payload: fields)
```

See [API guide](Documentation/API.md), [authentication](Documentation/Authentication.md), [Bulk and CSV](Documentation/Bulk.md), and [validation](Documentation/Validation.md). Compilable consumers are in [Examples](Examples).

## Scope

REST records, queries/queryAll, SOSL, descriptions, limits, Composite/Batch/Graph/Tree/Collections, OAuth PKCE/refresh/client credentials/JWT, and Bulk ingest/query are included. SOQL query builders, CSV-to-Codable mapping, built-in credential storage, SOAP Metadata, Tooling, and event subscriptions are outside this release.

## Dependencies and ownership

Swift Crypto `4.5.2..<6.0.0` supplies PKCE hashing and RS256 signing. The optional adapter uses AsyncHTTPClient `1.36.2..<2.0.0`. `client.shutdown()` closes only the default transport the client creates. Call `transport.shutdown()` for an adapter you create; an injected HTTPClient remains owned by its caller and **must be configured with redirects disabled**.

## Tests

Run `swift test`. Unit tests use fixtures; transport tests start a loopback Python 3 HTTP server and require no Salesforce account. CI tests macOS/Linux and both Crypto major versions, compiles the examples, and builds for the iOS device SDK. See the validation document for locally verified results and manual sandbox steps.
