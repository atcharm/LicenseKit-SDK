import Foundation
import LicenseKit

/// The fictional product this demo licenses.
///
/// Everything here is the vocabulary *your* app would define once and share
/// between its licensing code and its fulfilment backend.
public enum DemoProduct {
    /// The product identifier the app checks against. A license issued for any
    /// other product is rejected by `ProductRule`, however valid it is.
    public static let id: ProductID = "com.example.aperture"

    public static let name = "Aperture"

    public static let reference = ProductReference(id: id, name: name, edition: "studio")

    /// Reverse-DNS identifier of the issuing authority, recorded in every
    /// license and covered by the signature.
    public static let issuer = "com.example.licensing"

    /// Any fixed, product-specific string. It is not a secret — it exists so
    /// the device fingerprint this product computes cannot be correlated with
    /// the fingerprint another vendor computes for the same machine.
    public static let fingerprintSalt = "aperture-demo-2026"

    /// Used for the file store's subdirectory and the keychain service name.
    public static let bundleIdentifier = "com.example.aperture"
}

/// The capabilities the app gates on.
///
/// Note what these names are *not*: they are not "pro", "plus", or "team".
/// Entitlement identifiers are code concepts and should outlive every pricing
/// page you will ever ship. Which tier grants `export.raw` is a decision made at
/// issuance time; the gate in the app never changes.
public enum DemoEntitlement {
    public static let exportPDF: EntitlementID = "export.pdf"
    public static let exportRAW: EntitlementID = "export.raw"
    public static let cloudSync: EntitlementID = "sync.cloud"
    public static let batchProcess: EntitlementID = "batch.process"

    /// Display metadata for the feature-gate screen.
    public struct Descriptor: Sendable, Identifiable, Hashable {
        public let id: EntitlementID
        public let title: String
        public let summary: String
        public let symbol: String
        /// Whether this capability carries a numeric ceiling worth showing.
        public let usesLimit: Bool

        public init(
            id: EntitlementID,
            title: String,
            summary: String,
            symbol: String,
            usesLimit: Bool = false
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.symbol = symbol
            self.usesLimit = usesLimit
        }
    }

    public static let all: [Descriptor] = [
        Descriptor(
            id: exportPDF,
            title: "Export as PDF",
            summary: "Write a print-ready PDF of the current edit.",
            symbol: "doc.richtext"
        ),
        Descriptor(
            id: exportRAW,
            title: "Export RAW",
            summary: "Round-trip the original sensor data.",
            symbol: "camera.aperture"
        ),
        Descriptor(
            id: cloudSync,
            title: "Cloud sync",
            summary: "Mirror the library across devices.",
            symbol: "arrow.triangle.2.circlepath.icloud",
            usesLimit: true
        ),
        Descriptor(
            id: batchProcess,
            title: "Batch processing",
            summary: "Apply an edit across a whole shoot.",
            symbol: "square.stack.3d.down.right"
        ),
    ]

    /// Everything a top-tier license grants, with a three-device ceiling on
    /// cloud sync so the demo has a limit to display.
    public static let studioSet: EntitlementSet = [
        Entitlement(id: exportPDF),
        Entitlement(id: exportRAW),
        Entitlement(id: cloudSync, limit: 3),
        Entitlement(id: batchProcess),
    ]

    /// A cheaper tier. The gate in the app is identical; only the grant differs.
    public static let standardSet: EntitlementSet = [
        Entitlement(id: exportPDF),
        Entitlement(id: cloudSync, limit: 1),
    ]
}
