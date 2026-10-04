// swift-tools-version: 5.9

import PackageDescription

// Meta's SDK as a Swift package, pinned EXACTLY. 18.1.1 is the latest release
// (27 Aug 2026); facebook-ios-sdk's main branch already names 19.0.0, whose tag
// does not exist yet, so anything looser than an exact pin can resolve to a
// version that will not build.
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
