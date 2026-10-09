// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "SalesforceVaporExample", platforms: [.macOS(.v13)],
  dependencies: [
    .package(path: "../.."), .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0"),
  ],
  targets: [
    .executableTarget(
      name: "App",
      dependencies: [
        .product(name: "SalesforceAsyncHTTPClient", package: "swift-salesforce"),
        .product(name: "Salesforce", package: "swift-salesforce"),
        .product(name: "Vapor", package: "vapor"),
      ])
  ], swiftLanguageModes: [.v6])
