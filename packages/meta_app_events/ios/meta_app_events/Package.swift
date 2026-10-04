// swift-tools-version: 5.9

import PackageDescription

// Meta's SDK as a Swift package, pinned EXACTLY, and kept in step with the
// podspec beside it. Never loosen the pin: in Aug 2026 facebook-ios-sdk's main
// branch already named a 19.0.0 with no tag, and its privacy manifest is what
// the App Store privacy label is built from, so a new version must be reviewed
// before it ships. .github/workflows/meta-sdk-update.yml proposes each newer
// stable release weekly, with the manifests compared.
//
// FacebookCore is the whole requirement: App Events, Aggregated Event
// Measurement and SKAdNetwork reporting. No Login, no Share.
let package = Package(
  name: "meta_app_events",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    .library(name: "meta-app-events", targets: ["meta_app_events"])
  ],
  dependencies: [
    .package(url: "https://github.com/facebook/facebook-ios-sdk", exact: "18.1.1")
  ],
  targets: [
    .target(
      name: "meta_app_events",
      dependencies: [
        .product(name: "FacebookCore", package: "facebook-ios-sdk")
      ]
    )
  ]
)
