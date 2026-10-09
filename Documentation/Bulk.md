# Bulk API 2.0 and CSV

```swift
let created = try await client.bulk.createIngest(object: "Account", operation: .insert)
let job = created.value.reference
let csv = CSVWriter().stream(rows: [["Name"], ["Example, Inc."]])
try await client.bulk.upload(job, body: .stream(csv))
try await client.bulk.complete(job)
try await client.bulk.waitUntilComplete(job)
let results = try await client.bulk.ingestResults(job, result: .successful)
for try await row in CSVReader(results.body) { print(row) }
```

Ingest operations are insert, update, upsert, delete and hardDelete. Upsert requires an external ID field. Upload accepts `.data`, `.file`, or `.stream`; the URLSession transport spools asynchronous uploads to a temporary file and removes it after completion, error or cancellation. The server adapter sends streams directly. Each byte stream is single-consumer. Readers apply backpressure; Apple platforms use URLSession AsyncBytes with 64 KiB output chunks; Linux uses a dedicated serial delegate queue and a single 64 KiB handoff, waiting until a reader frees that chunk. Foundation retains ownership of its underlying networking buffers. File and CSV reader buffers are bounded by chunk/field/row limits. An application-defined source controls the size of its own chunks.

`createQuery` accepts SOQL and query/queryAll operations. `list`, `inspect`, `abort`, and `delete` support both job kinds; `complete` marks an ingest upload ready. Job references retain their API version independently of client configuration. Job references conform to Codable for persistence. Listings use each job’s reported creation version when available; retain the reference if resuming a job later.

```swift
let job = try await client.bulk.createQuery("SELECT Id, Name FROM Account").value
try await client.bulk.waitUntilComplete(job.reference)
for try await row in client.bulk.queryRows(job.reference, maxRecords: 10_000) {
    print(row)
}
```

Query rows emit a header once, check each later page's header and row width, and follow only the server's `Sforce-Locator` until `null`. Pass the job's delimiter when using a non-comma job. `queryResults` exposes a single raw CSV result page for custom processing. Salesforce requires the creation API version for results; see the [Bulk query results contract](https://developer.salesforce.com/docs/platform/api-asynch/guide/query-get-job-results.html).

Polling defaults to two seconds with a fifteen-minute timeout. Cancellation or timeout leaves the remote job intact. Inspect or explicitly abort it as appropriate. Job failure/abort produces a Bulk error.

CSV supports all Salesforce delimiters, LF/CRLF, doubled quotes, multiline fields, BOM, and split UTF-8. Malformed quotes and invalid UTF-8 fail rather than being replaced. Default field/row limits are 8/32 MiB and can be configured. `CSVWriter.encode` writes one row; use it with your own asynchronous producer for large input. The convenience `stream(rows:)` accepts an already available array and does not fetch or map records automatically. Salesforce Bulk null semantics (`#N/A`) and field type conversion remain the caller's responsibility.
