// swift-tools-version: 5.9

import PackageDescription

// Meta's SDK as a Swift package, pinned EXACTLY, and kept in step with the
// podspec beside it. Never loosen the pin: in Aug 2026 facebook-ios-sdk's main
// branch already named a 19.0.0 with no tag, and its privacy manifest is what
// the App Store privacy label is built from, so a new version must be reviewed
// before it ships. .github/workflows/sdk-update.yml proposes each newer
// stable release weekly, with the manifests compared.
//
// FacebookCore is the whole requirement: App Events, Aggregated Event
// Measurement and SKAdNetwork reporting. No Login, no Share.
//
// TikTok's App Events SDK beside it, pinned EXACTLY for the same reason (added
// 8 Oct 2026; 1.7.2 is the latest stable release). Its privacy manifest declares
// almost nothing although it reads the advertising identifier and device details,
// so the App Store label for it is built from what it does, not from that file.
// The same weekly workflow proposes its updates and scans its source for what it reads.
let package = Package(
  name: "meta_app_events",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    .library(name: "meta-app-events", targets: ["meta_app_events"])
  ],
  dependencies: [
    .package(url: "https://github.com/facebook/facebook-ios-sdk", exact: "18.1.1"),
    .package(url: "https://github.com/tiktok/tiktok-business-ios-sdk", exact: "1.7.2"),
  ],
  targets: [
    .target(
      name: "meta_app_events",
      dependencies: [
        .product(name: "FacebookCore", package: "facebook-ios-sdk"),
        .product(name: "TikTokBusinessSDK", package: "tiktok-business-ios-sdk"),
      ]
    )
  ]
)
