// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "swift-salesforce",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "Salesforce", targets: ["Salesforce"]),
    .library(name: "SalesforceAsyncHTTPClient", targets: ["SalesforceAsyncHTTPClient"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", "4.5.2"..<"6.0.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", "1.36.2"..<"2.0.0"),
  ],
  targets: [
    .target(
      name: "Salesforce",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "CryptoExtras", package: "swift-crypto"),
      ]),
    .target(
      name: "SalesforceAsyncHTTPClient",
      dependencies: ["Salesforce", .product(name: "AsyncHTTPClient", package: "async-http-client")]),
    .testTarget(
      name: "SalesforceTests",
      dependencies: [
        "Salesforce", "SalesforceAsyncHTTPClient",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "CryptoExtras", package: "swift-crypto"),
      ], exclude: ["server.py"]),
  ],
  swiftLanguageModes: [.v6]
)
