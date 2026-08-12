// swift-tools-version: 6.0
import PackageDescription

// Aperture — a worked example of integrating LicenseKit into a real app.
//
// This demo lives inside the LicenseKit SDK distribution, so it integrates the
// SDK exactly the way you will: through the prebuilt XCFrameworks published with
// each release. There is no source checkout involved and no privileged access —
// if this builds for you, your own app will too.
//
// Two targets, and the split between them is the point:
//
//   LicenseKitDemo   the app. Links `LicenseKit` and nothing else. This is the
//                    only target whose code you should copy into your own app.
//   DemoBackstage    a stand-in for your fulfilment backend. Links
//                    `LicenseKitVendor`, which holds the private-key type that
//                    mints licenses. In production this code runs on a server
//                    you control — never inside a shipping app.
//
// The demo links both so it can be self-contained: it issues its own licenses
// and answers its own API calls, with no server and no network.
let package = Package(
    name: "LicenseKitDemo",
    // macOS only, because DemoBackstage links the vendor tooling and that ships
    // for macOS alone. The app target itself uses nothing platform-specific
    // beyond SwiftUI and two file panels.
    //
    // macOS 14 for `@Observable`, which is what the SDK's integration guide
    // recommends for mirroring `LicenseState` into a view layer. LicenseKit
    // itself supports macOS 12 and iOS 15 — the floor here is the demo's, not
    // the SDK's.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LicenseKitDemo", targets: ["LicenseKitDemo"]),
    ],
    dependencies: [
        // Resolved against the distribution package sitting two directories up,
        // so the demo always matches the release it shipped in.
        //
        // In your own app, depend on it by URL instead:
        //
        //   .package(
        //       url: "https://github.com/gumbracelet/LicenseKit-SDK.git",
        //       from: "1.0.0"
        //   )
        //
        // Either way you get the same prebuilt XCFrameworks; the only difference
        // is where SwiftPM reads the manifest from.
        .package(name: "LicenseKit", path: "../.."),
    ],
    targets: [
        .target(
            name: "DemoBackstage",
            dependencies: [
                .product(name: "LicenseKit", package: "LicenseKit"),
                // Vendor-side issuing tools. Depend on this from your licensing
                // service, never from your app — it is a separate product
                // precisely so that mistake takes a deliberate act.
                .product(name: "LicenseKitVendor", package: "LicenseKit"),
            ]
        ),
        .executableTarget(
            name: "LicenseKitDemo",
            dependencies: [
                .product(name: "LicenseKit", package: "LicenseKit"),
                "DemoBackstage",
            ]
        ),
        // The integration tests an app of this shape should actually have. They
        // link no user interface: every non-deterministic input the SDK has —
        // clock, store, transport, machine identity — is injectable, so the whole
        // licensing lifecycle is testable with no network and no sleeping.
        .testTarget(
            name: "LicenseKitDemoTests",
            dependencies: [
                "DemoBackstage",
                .product(name: "LicenseKit", package: "LicenseKit"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
