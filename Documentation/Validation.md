# Validation

## Automated checks

The Swift Testing suite uses offline response fixtures and injectable transports. It covers:

- API versions, paths, query encoding, CRUD, external IDs, omitted/null fields, decimal JSON, dates, descriptions and search.
- Lazy SOQL pages and flattened records, continuation trust checks, Composite/Batch/Graph/Tree/Collection partial failures.
- Shared renewal, cancelled waiters, stale generations, rotated refresh tokens, storage failures, loaded sessions, PKCE/state, RS256 signatures and client credentials.
- Read retry limits and write protection, invalid-session replay limits, retry and polling cancellation, inspection deadlines.
- Bulk ingest/query lifecycle, result locators, job API versions, page headers, CSV quoting, CRLF, BOM, invalid UTF-8 and byte-sized chunks.
- Both URLSession and AsyncHTTPClient against a Python loopback server: 8 MiB downloads with slow consumers, output chunk bounds, redirects, data/file/asynchronous uploads, interrupted connections, cancellation and explicit shutdown.
- Upload spool deletion after success, source failure and cancellation.

Run `swift test` with Python 3 on PATH. A sandbox must allow loopback binding. No Salesforce credentials are used. Test code never creates simulators or installs tools.

CI runs Swift 6.4 tests on macOS and Linux with Crypto 4.5.2 and 5.0.0. It compiles the Apple consumer and cross-compiles for the iOS device SDK. Separate consumer jobs resolve Hummingbird and Vapor with compatible dependencies; Vapor 4 currently resolves Crypto 4, while Hummingbird resolves Crypto 5. The library's declared range supports both. Keep each consumer's build directory separate: SwiftPM can otherwise reuse a stale graph when switching root packages.

## Local verification

The implementation was checked using Apple Swift 6.4 and the installed Xcode device SDK. Local results:

| Check | Result |
| --- | --- |
| macOS unit and HTTP transport tests, Crypto 4.5.2 | 29 tests passed |
| macOS unit and HTTP transport tests, Crypto 5.0.0 | 29 tests passed |
| Delegate fallback forced on macOS, Crypto 5.0.0 | 3 transport tests passed |
| Apple consumer and core library, arm64 iOS 16 deployment target | Compiled with installed device SDK |
| Hummingbird 2 consumer, Crypto 5 | Compiled on macOS (consumer requires macOS 14) |
| Vapor 4 consumer, Crypto 4 | Compiled on macOS |

The fallback can be exercised with `swift test -Xswiftc -DSALESFORCE_FORCE_DELEGATE_TRANSPORT --filter TransportTests`. This checks the delegate handoff mechanics on macOS; it does not establish Linux runtime compatibility. Builds establish compile compatibility, not device or Salesforce runtime behavior.

Local Linux runtime verification is unavailable because Docker's daemon is unreachable. The Linux CI jobs are configured but have not been run from this workspace. iOS runtime verification and live Salesforce sandbox requests have not been performed. No simulator or runtime was installed.

Foundation owns its internal networking buffers. The package bounds its own output chunks and delegate handoff; the tests exercise slow consumers and chunk limits but do not measure a strict process-wide RSS ceiling. AsyncHTTPClient supplies its own streaming backpressure.

## Manual sandbox validation

Use a dedicated Salesforce sandbox and a connected app/external client app with the relevant grants and user permissions. Choose an explicit API version supported by that org. Never check tokens, secrets, private keys or test org data into the repository.

1. Present a PKCE authorization URL, exchange its callback, and confirm the returned instance URL is used. Reject a changed state. Refresh and verify that the application token store saves the resulting session.
2. With the org's supported server configuration, test client credentials and a certificate registered for JWT bearer authentication. Confirm an expired or unregistered assertion fails.
3. Create a disposable Account, retrieve it into a caller-defined Codable model, update a field, clear it with a dynamic `.null` payload, look it up/upsert through a disposable custom external ID field, and delete it.
4. Query enough records to produce a continuation. Iterate queryAll with suitable permissions, run a SOSL search, and inspect describe/limits response metadata.
5. Submit Composite subrequests containing both a valid and deliberately invalid operation. Inspect every status/error; repeat with Batch, Graph, Tree and Collections using the org's supported API version.
6. Create a small Bulk ingest job from CSV including a quoted delimiter and multiline field. Complete and poll it, then inspect successful, failed and unprocessed results. Use disposable records and appropriate permissions before testing delete/hardDelete.
7. Create a Bulk query job, poll it, use a small maxRecords value to force locators, and verify stable headers across pages. Reuse the creation API version. Cancel a local polling task, confirm the remote job remains inspectable, then explicitly abort/delete it as appropriate.
8. Inspect API-limit observations and clean up all disposable jobs and records.

These steps require live access and are intentionally manual; offline passing tests do not establish Salesforce org permissions or connected-app configuration.
