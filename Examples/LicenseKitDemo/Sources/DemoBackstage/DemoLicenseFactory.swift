import Foundation
import LicenseKit
import LicenseKitVendor

/// One of the license files the demo can mint on demand.
///
/// Each case is a situation a real support queue produces, paired with what the
/// SDK is expected to do about it. Together they cover every built-in rule that
/// an offline, file-licensed app can trip.
public enum OfflineScenario: String, CaseIterable, Sendable, Identifiable {
    case perpetual
    case subscription
    case expiringSoon
    case withinExpiryGrace
    case expired
    case notYetValid
    case wrongProduct
    case versionCeiling
    case untrustedIssuer
    case tampered
    case sealed
    case bundle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .perpetual: return "Perpetual, everything unlocked"
        case .subscription: return "Subscription, 45 days left"
        case .expiringSoon: return "Subscription, 5 days left"
        case .withinExpiryGrace: return "Expired yesterday, 3-day grace"
        case .expired: return "Expired 10 days ago"
        case .notYetValid: return "Starts in a week"
        case .wrongProduct: return "Licensed for a different product"
        case .versionCeiling: return "Perpetual fallback, up to 1.9.0"
        case .untrustedIssuer: return "Signed by a key you don't trust"
        case .tampered: return "Edited after signing"
        case .sealed: return "Encrypted container"
        case .bundle: return "Two licenses in one file"
        }
    }

    /// What the customer did to end up here.
    public var summary: String {
        switch self {
        case .perpetual:
            return "A one-time purchase of the Studio edition, three seats."
        case .subscription:
            return "A healthy monthly subscription. Nothing to report."
        case .expiringSoon:
            return "Inside the 14-day warning threshold, so validation still "
                + "passes but carries a warning to surface."
        case .withinExpiryGrace:
            return "The renewal has not landed yet. The policy's 3-day expiry "
                + "grace absorbs a card that declined on a Friday."
        case .expired:
            return "The grace period has also elapsed. There is no honest "
                + "reading of this license as still in force."
        case .notYetValid:
            return "A pre-order, or a clock that is a week behind."
        case .wrongProduct:
            return "A valid license for another app in the same catalogue."
        case .versionCeiling:
            return "The customer keeps the versions they paid for; upgrades "
                + "past 1.9.0 need a renewal. Set the running version in Setup "
                + "to see both sides of the bound."
        case .untrustedIssuer:
            return "Correctly signed — by a key this build does not carry."
        case .tampered:
            return "A genuine license whose JSON gained an extra entitlement "
                + "after it was signed. This is the attack the signature exists "
                + "to stop."
        case .sealed:
            return "The same license, encrypted. Install it with and without a "
                + "decryption key configured."
        case .bundle:
            return "A site-license container. `installLicenseFile` handles one "
                + "license; a bundle needs `LicenseFileReader.read(_:)`."
        }
    }

    /// The outcome to expect, phrased as the SDK reports it.
    public var expectation: String {
        switch self {
        case .perpetual: return "licensed — no warnings"
        case .subscription: return "licensed — no warnings"
        case .expiringSoon: return "licensed — warning: expiringSoon"
        case .withinExpiryGrace: return "licensed — warning: withinExpiryGrace"
        case .expired: return "install throws — validation: expired"
        case .notYetValid: return "install throws — validation: notYetValid"
        case .wrongProduct: return "install throws — validation: productMismatch"
        case .versionCeiling: return "depends on the running version — versionNotCovered above 1.9.0"
        case .untrustedIssuer: return "install throws — validation: unknownSigningKey"
        case .tampered: return "install throws — validation: signatureInvalid"
        case .sealed: return "format error without a key; licensed with one"
        case .bundle: return "format error — the file holds 2 licenses"
        }
    }

    /// Whether reading this file needs a `LicenseFileReader` with a sealing key.
    public var isSealed: Bool { self == .sealed }

    var licenseID: LicenseID { LicenseID(rawValue: "demo-offline-\(rawValue)") }

    var licenseKey: LicenseKey {
        // Readable, stable keys so the demo can be followed without copying
        // 20 random characters around.
        LicenseKey(rawValue: "APERT-FILE-\(rawValue.uppercased().prefix(9))")
    }
}

/// Mints the demo's license files.
///
/// - Warning: The real version of this type runs on your server. It holds a
///   private signing key; anything that can call it can issue licenses for your
///   product.
///
/// Everything here uses `LicenseIssuer` and `LicenseSpecification` exactly as a
/// fulfilment backend would — the only unusual part is ``tamperedFile()``, which
/// deliberately corrupts its own output.
public struct DemoLicenseFactory: Sendable {
    private let clock: any LicenseClock

    public init(clock: any LicenseClock) {
        self.clock = clock
    }

    private var customer: LicenseSubject {
        LicenseSubject(
            customerID: "cus_4A19F0",
            name: "Dana Okonkwo",
            email: "dana@northlight.example",
            organization: "Northlight Studio"
        )
    }

    // MARK: - Files

    /// Issues the container for a scenario, ready to hand to
    /// `LicenseManager.installLicenseFile(_:)`.
    public func file(for scenario: OfflineScenario) throws -> Data {
        switch scenario {
        case .tampered:
            return try tamperedFile()
        case .untrustedIssuer:
            return try untrustedFile()
        case .sealed:
            return try sealedIssuer().issueFile(specification(for: .perpetual))
        case .bundle:
            return try bundleFile()
        default:
            return try issuer().issueFile(specification(for: scenario))
        }
    }

    /// The base64 text form, as a customer would receive it by email.
    public func text(for scenario: OfflineScenario) throws -> String {
        try LicenseEnvelope(serialized: try file(for: scenario)).base64Text()
    }

    public func suggestedFilename(for scenario: OfflineScenario) -> String {
        "aperture-\(scenario.rawValue).\(LicenseEnvelope.fileExtension)"
    }

    // MARK: - Specifications

    /// Builds the claim set for a scenario.
    ///
    /// Read this as the catalogue of things a policy can express. Every field
    /// set here is covered by the signature and cannot be changed afterwards
    /// without invalidating it.
    func specification(for scenario: OfflineScenario) -> LicenseSpecification {
        let now = clock.now

        var specification: LicenseSpecification
        switch scenario {
        case .perpetual, .sealed, .bundle, .tampered, .untrustedIssuer:
            specification = .perpetual(
                product: DemoProduct.reference,
                issuer: DemoProduct.issuer,
                subject: customer,
                entitlements: DemoEntitlement.studioSet,
                seats: 3
            )

        case .subscription:
            specification = .subscription(
                product: DemoProduct.reference,
                issuer: DemoProduct.issuer,
                expiresAt: now.addingTimeInterval(.licenseDays(45)),
                subject: customer,
                entitlements: DemoEntitlement.studioSet,
                seats: 2
            )

        case .expiringSoon:
            specification = .subscription(
                product: DemoProduct.reference,
                issuer: DemoProduct.issuer,
                expiresAt: now.addingTimeInterval(.licenseDays(5)),
                subject: customer,
                entitlements: DemoEntitlement.studioSet,
                seats: 2
            )

        case .withinExpiryGrace:
            specification = .subscription(
                product: DemoProduct.reference,
                issuer: DemoProduct.issuer,
                expiresAt: now.addingTimeInterval(-.licenseDays(1)),
                subject: customer,
                entitlements: DemoEntitlement.studioSet,
                expiryGrace: .licenseDays(3)
            )

        case .expired:
            specification = .subscription(
                product: DemoProduct.reference,
                issuer: DemoProduct.issuer,
                expiresAt: now.addingTimeInterval(-.licenseDays(10)),
                subject: customer,
                entitlements: DemoEntitlement.studioSet,
                expiryGrace: .licenseDays(3)
            )

        case .notYetValid:
            specification = LicenseSpecification(
                product: DemoProduct.reference,
                issuer: DemoProduct.issuer,
                subject: customer,
                policy: LicensePolicy(
                    kind: .subscription,
                    validity: ValidityWindow(
                        notBefore: now.addingTimeInterval(.licenseDays(7)),
                        expiresAt: now.addingTimeInterval(.licenseDays(372))
                    )
                ),
                entitlements: DemoEntitlement.studioSet
            )

        case .wrongProduct:
            specification = .perpetual(
                product: ProductReference(
                    id: "com.example.aperture-video",
                    name: "Aperture Video"
                ),
                issuer: DemoProduct.issuer,
                subject: customer,
                entitlements: DemoEntitlement.standardSet
            )

        case .versionCeiling:
            specification = .perpetual(
                product: DemoProduct.reference,
                issuer: DemoProduct.issuer,
                subject: customer,
                entitlements: DemoEntitlement.studioSet,
                maximumVersion: "1.9.0"
            )
        }

        specification.id = scenario.licenseID
        specification.key = scenario.licenseKey
        specification.metadata["demo.scenario"] = .string(scenario.rawValue)
        // Deliberately a string rather than `.date(now)`.
        //
        // `MetadataValue.date` canonicalises as an integer count of milliseconds,
        // but its JSON form is an ISO-8601 *string* — and `MetadataValue`'s
        // decoder has no way to tell that string from any other, so it comes back
        // as `.string`. Sign over `.date`, verify after a round-trip through
        // `.string`, and the canonical bytes differ: the signature never
        // verifies, anywhere.
        //
        // Storing the timestamp as text sidesteps it, because a string round-trips
        // to itself. `ISO8601Timestamp` also drops sub-second precision, which is
        // the same reason every `Date` that participates in a signature is floored
        // to a whole second — see `Date.truncatedToSecond`.
        specification.metadata["demo.issuedAt"] = .string(ISO8601Timestamp.string(from: now))
        return specification
    }

    // MARK: - Issuers

    private func issuer() throws -> LicenseIssuer {
        LicenseIssuer(signingKey: try DemoVendorKeys.signingKey(), clock: clock)
    }

    private func sealedIssuer() throws -> LicenseIssuer {
        LicenseIssuer(
            signingKey: try DemoVendorKeys.signingKey(),
            sealingKey: try DemoVendorKeys.sealingKey(),
            keyHint: DemoVendorKeys.keyID,
            clock: clock
        )
    }

    private func untrustedFile() throws -> Data {
        let rogue = LicenseIssuer(
            signingKey: try DemoVendorKeys.untrustedSigningKey(),
            clock: clock
        )
        return try rogue.issueFile(specification(for: .untrustedIssuer))
    }

    /// Signs a legitimate license, then edits the claim set and repackages it
    /// with the *original* signature attached.
    ///
    /// This is the forgery the whole design exists to defeat, and it is worth
    /// running once: the added entitlement is present in the file, readable in a
    /// text editor, and rejected before any other rule gets a say — because
    /// `SignatureRule` runs first and the canonical bytes no longer match.
    private func tamperedFile() throws -> Data {
        let issuer = try issuer()
        var signed = try issuer.issue(specification(for: .tampered))
        signed.license.entitlements.insert(
            Entitlement(id: DemoEntitlement.exportRAW, limit: nil)
        )
        signed.license.entitlements.insert(
            Entitlement(id: EntitlementID(rawValue: "everything.forever"))
        )
        return try issuer.package(signed)
    }

    /// A container holding two licenses, as a site-license delivery would.
    private func bundleFile() throws -> Data {
        let issuer = try issuer()

        var first = specification(for: .perpetual)
        first.id = LicenseID(rawValue: "demo-site-seat-1")
        first.key = "APERT-SITE-SEAT1"
        first.subject = LicenseSubject(name: "Seat 1", organization: "Northlight Studio")

        var second = first
        second.id = LicenseID(rawValue: "demo-site-seat-2")
        second.key = "APERT-SITE-SEAT2"
        second.subject = LicenseSubject(name: "Seat 2", organization: "Northlight Studio")

        return try issuer.package([try issuer.issue(first), try issuer.issue(second)])
    }
}
