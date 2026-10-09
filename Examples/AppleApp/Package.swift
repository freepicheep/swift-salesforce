// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "AppleSalesforceExample", platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "AppleSalesforceExample", targets: ["AppleSalesforceExample"])],
  dependencies: [.package(path: "../..")],
  targets: [
    .target(
      name: "AppleSalesforceExample",
      dependencies: [.product(name: "Salesforce", package: "swift-salesforce")], path: "Sources")
  ], swiftLanguageModes: [.v6])
