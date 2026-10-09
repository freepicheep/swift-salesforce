// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "SalesforceHummingbirdExample", platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../.."),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
  ],
  targets: [
    .executableTarget(
      name: "App",
      dependencies: [
        .product(name: "SalesforceAsyncHTTPClient", package: "swift-salesforce"),
        .product(name: "Salesforce", package: "swift-salesforce"),
        .product(name: "Hummingbird", package: "hummingbird"),
      ])
  ], swiftLanguageModes: [.v6])
