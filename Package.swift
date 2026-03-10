// swift-tools-version: 5.9
// This is primarily an Xcode project, but Package.swift is included for reference

import PackageDescription

let package = Package(
    name: "PhotoVault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoVault", targets: ["PhotoVault"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "PhotoVault",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources"
        )
    ]
)

/*
 NOTE: This Package.swift is for reference only.
 
 PhotoVault is a macOS app that requires:
 - Photos.framework (system)
 - AuthenticationServices (system)
 - SwiftUI (system)
 
 These system frameworks are not available via SPM.
 Use the Xcode project for actual builds.
 
 To create the Xcode project:
 1. Create new macOS App in Xcode
 2. Add GRDB via File → Add Package Dependencies
 3. Copy Sources/*.swift to the project
 4. Configure entitlements (see docs/GOOGLE_CLOUD_SETUP.md)
 */
