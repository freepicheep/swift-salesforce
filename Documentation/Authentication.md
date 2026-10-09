# Authentication

`SalesforceLoginDomain` supports production, sandbox, or a custom HTTPS login origin. API requests use the instance URL returned by the token endpoint.

## Authorization code and PKCE

```swift
let oauth = SalesforceOAuth(clientID: clientID, domain: .sandbox)
let transaction = try oauth.authorization(redirectURI: redirectURI)
// Present transaction.url using the app's browser integration.
let session = try await oauth.exchange(callback: callbackURL, authorization: transaction)
let auth = SalesforceAuthentication(session: session, store: appTokenStore) { previous in
    guard let previous else { throw SalesforceError.authentication("Sign in first") }
    return try await oauth.refresh(previous)
}
```

The helper generates a cryptographically random verifier and state, hashes the verifier with SHA256, and validates the callback destination and state. Retain transactions only until the callback is exchanged, then discard them; the application must prevent callback reuse. Browser presentation, callback routing and sign-out UX belong to the app. A connected app requiring a client secret can pass it to exchange/refresh; do not embed confidential server secrets in shipped apps.

## Servers

Use `SalesforceAuthentication { _ in try await oauth.clientCredentials(clientSecret: secret) }` for a client credentials connected app configured with a run-as user. For JWT bearer, supply username, PEM RSA private key, and the OAuth client ID to `oauth.jwtBearer`; assertions are signed with RS256 and expire within three minutes. Store keys and secrets in your server's secret manager. Renew JWT/client-credentials sessions by invoking that grant again.

## Persistence and concurrency

Sessions stay in memory unless a `SalesforceTokenStore` is supplied. Implement its async `load`/`save` methods using your platform's credential storage. Rotated refresh tokens replace old ones; absent refresh tokens retain the previous token. Store failures surface as `tokenStorage`; a successfully renewed session remains in memory, and callers may inspect `currentSession()` to repair persistence. Applications save the initial authorization-code session themselves.

Renewals share one actor-managed task. Session generations ensure a delayed invalid-session failure cannot replace newer credentials. Cancelling one caller leaves the shared renewal available for other requests; cancellation is delivered to the cancelled waiter when renewal settles. A failed renewal leaves prior credentials in memory and permits a later explicit retry. Individual waiter cancellation is not an immediate interruption of a shared token endpoint request.

For an already available token use `AccessTokenProvider`. It cannot renew and surfaces an authentication error on confirmed expiry. A custom `SalesforceTokenProvider` returns generation-tagged credentials and implements `renew(invalidating:)`; it must handle its own concurrency and stale-generation protection.
