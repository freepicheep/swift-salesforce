# API guide

`SalesforceClient` is a Sendable value containing configuration, a transport, and a token provider. Copying it shares those dependencies. Mutable authentication state belongs to `SalesforceAuthentication`, an actor. Configuration accepts a numeric API version, fresh codec factories, retry policy, JSON collection limit, and an optional Sendable observation callback.

## REST

- `records.create(_:payload:)`, `retrieve(_:id:fields:as:)`, `update(_:id:payload:)`, and `delete(_:id:)` operate on standard or custom objects.
- `retrieve(_:externalIDField:value:as:)` and `upsert(_:externalIDField:value:payload:)` percent-encode external ID values. Upsert returns an optional `SaveResult`: HTTP 204 updates have no body; HTTP 201 creations have a result.
- `versions()`, `resources()`, `objects()`, `describe(_:)`, and `limits()` expose discovery and org metadata.
- Payloads conform to `Encodable & Sendable`; results conform to `Decodable & Sendable`. Salesforce field names are case sensitive. Define CodingKeys for your own naming conventions.

`SalesforceRecord` wraps a dictionary of `JSONValue`, supporting objects, arrays, strings, booleans, Decimal numbers, and explicit null. JSON numbers beyond Decimal's representable precision/range require a caller-supplied decoder/model. Salesforce date-only fields use `SalesforceDate`; Foundation `Date` uses Salesforce datetime codecs. Each operation creates its own encoder/decoder, avoiding shared mutable codecs. Custom factories must return independent instances.

## Queries and search

`queries.page(_:queryAll:as:)` returns one `QueryPage<T>`. `queries.pages` yields responses per page; `queries.records` flattens them. No request occurs until iteration starts. Continuation URLs are honored and validated against the authenticated instance origin and `/services/data/` path. Repeated continuation URLs fail. `search.search(_:as:)` accepts a complete SOSL string and a caller-defined result envelope.

Use `SOQL.literal` for quoted string literals and `SOSL.literal` to escape a search term. These helpers do not validate complete statements or replace access controls.

## Composite

`composite.execute` returns each subrequest's body, headers, status, reference, and derived errors. Successful HTTP responses can contain failed subrequests; inspect `hasErrors` and each `isSuccess`. `batch` returns every status and result. `graphs` preserves graph success flags and the complete dynamic graph response; `tree` preserves reference IDs and errors. Collection create/update/upsert/delete return arrays of `SaveResult`; collection retrieve returns an array with optional entries.

Tree records and collection payloads must contain Salesforce's required `attributes` structure. Reference expressions such as `@{ref.id}` remain caller-defined. Composite URLs are API-relative; external URLs are rejected.

## Additional endpoints

`request(_:path:query:payload:as:)` encodes JSON; the lower-level overload accepts a `SalesforceRequestBody`. `stream` returns HTTP metadata and a demand-driven byte stream. Paths must stay under `/services/data/`. Automatic redirects are disabled by the provided transports; a redirect returns a structured HTTP error through the client. This avoids forwarding credentials to an unchecked redirect target.

`SalesforceResponse` includes status, headers, and parsed `Sforce-Limit-Info`. Observation callbacks report each attempt's time to response headers, status and limits; they do not include credentials or query strings, and do not measure full download time. Callbacks must be brief and thread safe.

GET/HEAD transient errors retry with exponential backoff and optional jitter, up to three total attempts by default. Retry-After seconds or HTTP dates are respected up to the configured maximum delay. Writes never retry after transient failure. A confirmed HTTP 401 `INVALID_SESSION_ID` can trigger one credential renewal and one replay when the body is reproducible. Data and files are reproducible; asynchronous streams are not. Do not modify upload files during an operation. Failures during a successful response body download are surfaced rather than silently restarting the stream.

Errors distinguish validation, authentication, storage, Salesforce error arrays, HTTP bodies, decoding, CSV and Bulk failures. Underlying transport errors remain available for diagnosis; cancellation remains `CancellationError`.
