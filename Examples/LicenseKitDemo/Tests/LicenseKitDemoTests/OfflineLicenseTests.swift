import DemoBackstage
import Foundation
import LicenseKit
import Testing

/// Signed license files, and each rule they are built to trip.
@Suite("Offline license files")
struct OfflineLicenseTests {
    // MARK: - Accepted

    @Test("A perpetual license installs and grants everything it claims")
    func perpetualInstalls() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        let state = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .perpetual),
            reader: harness.reader
        )

        #expect(state.isLicensed)
        #expect(state.warnings.isEmpty)
        #expect(state.isEntitled(to: DemoEntitlement.batchProcess))
        #expect(state.record?.origin.medium == .offlineFile)
    }

    @Test("A subscription nearing its end is valid but carries a warning")
    func expiringSoonWarns() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        let state = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .expiringSoon),
            reader: harness.reader
        )

        #expect(state.isLicensed)
        #expect(state.report?.hasWarning {
            if case .expiringSoon = $0 { return true }; return false
        } == true)
        // A warning is not a grace period; the license is still in force.
        #expect(state.isRunningOnGrace == false)
    }

    @Test("A license inside its post-expiry grace still works, and says so")
    func expiryGraceIsHonoured() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        let state = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .withinExpiryGrace),
            reader: harness.reader
        )

        #expect(state.isLicensed)
        // This is what the grace window exists for: a card that declined on a
        // Friday must not lock a paying customer out mid-deadline.
        #expect(state.isRunningOnGrace)
        #expect(state.report?.hasWarning {
            if case .withinExpiryGrace = $0 { return true }; return false
        } == true)
    }

    @Test("A sealed container opens when the reader carries the key")
    func sealedFileOpensWithKey() async throws {
        let harness = try DemoHarness(signaturePolicy: .required, configuresSealingKey: true)

        let state = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .sealed),
            reader: harness.reader
        )

        #expect(state.isLicensed)
    }

    // MARK: - Rejected

    @Test("An expired license past its grace is refused and not stored")
    func expiredIsRefused() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        do {
            _ = try await harness.manager.installLicenseFile(
                try harness.factory.file(for: .expired),
                reader: harness.reader
            )
            Issue.record("expected an expired license to be refused")
        } catch LicenseKitError.validation(let report) {
            #expect(report.hasFailure { if case .expired = $0 { return true }; return false })
        }

        // Never persisted. Storing a license the app rejects on every launch
        // produces a permanently broken install with no obvious way out.
        #expect(try await harness.store.loadAll().isEmpty)

        // The *live* state is `.invalid`, not `.unlicensed`, and that distinction
        // is deliberate: the rejected record is kept in memory so the UI can show
        // which license failed and offer a renewal. Because nothing was written,
        // the next launch starts clean.
        #expect(await harness.manager.state.isInvalid)
        let relaunched = try harness.relaunched(signaturePolicy: .required)
        #expect(await relaunched.manager.start() == .unlicensed)
    }

    @Test("A license that has not started yet is refused")
    func notYetValidIsRefused() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        do {
            _ = try await harness.manager.installLicenseFile(
                try harness.factory.file(for: .notYetValid),
                reader: harness.reader
            )
            Issue.record("expected a future license to be refused")
        } catch LicenseKitError.validation(let report) {
            #expect(report.hasFailure { if case .notYetValid = $0 { return true }; return false })
        }
    }

    @Test("A valid license for a different product does not unlock this one")
    func wrongProductIsRefused() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        do {
            _ = try await harness.manager.installLicenseFile(
                try harness.factory.file(for: .wrongProduct),
                reader: harness.reader
            )
            Issue.record("expected a wrong-product license to be refused")
        } catch LicenseKitError.validation(let report) {
            #expect(report.hasFailure {
                if case .productMismatch = $0 { return true }; return false
            })
        }
    }

    @Test("A license edited after signing fails on the signature, before anything else")
    func tamperedFileFailsSignature() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        do {
            _ = try await harness.manager.installLicenseFile(
                try harness.factory.file(for: .tampered),
                reader: harness.reader
            )
            Issue.record("expected a tampered license to be refused")
        } catch LicenseKitError.validation(let report) {
            // The forged entitlement is present in the file and readable — and
            // irrelevant, because the canonical bytes no longer match.
            #expect(report.hasFailure { $0 == .signatureInvalid })
            #expect(report.rule(for: .signatureInvalid) == .signature)
        }
    }

    @Test("A license signed by an untrusted key is distinguished from a forgery")
    func untrustedIssuerIsNamed() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        do {
            _ = try await harness.manager.installLicenseFile(
                try harness.factory.file(for: .untrustedIssuer),
                reader: harness.reader
            )
            Issue.record("expected an untrusted issuer to be refused")
        } catch LicenseKitError.validation(let report) {
            // `.unknownSigningKey`, not `.signatureInvalid`: the app should say
            // "update the app", not "this is forged".
            #expect(report.hasFailure {
                if case .unknownSigningKey = $0 { return true }; return false
            })
        }
    }

    @Test("A sealed container cannot be opened without the key")
    func sealedFileFailsWithoutKey() async throws {
        let harness = try DemoHarness(signaturePolicy: .required, configuresSealingKey: false)

        do {
            _ = try await harness.manager.installLicenseFile(
                try harness.factory.file(for: .sealed),
                reader: harness.reader
            )
            Issue.record("expected a sealed file to need a key")
        } catch LicenseKitError.format(let error) {
            guard case .malformedContainer = error else {
                Issue.record("expected .malformedContainer, got \(error)")
                return
            }
        }
    }

    @Test("A multi-license container is refused by installLicenseFile and read by the reader")
    func bundleNeedsTheMultiLicensePath() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)
        let data = try harness.factory.file(for: .bundle)

        // Refused rather than silently picking one of them.
        do {
            _ = try await harness.manager.installLicenseFile(data, reader: harness.reader)
            Issue.record("expected a bundle to be refused by installLicenseFile")
        } catch LicenseKitError.format(let error) {
            guard case .decodingFailed = error else {
                Issue.record("expected .decodingFailed, got \(error)")
                return
            }
        }

        // The right path returns every license so the app can choose.
        let licenses = try harness.reader.read(data)
        #expect(licenses.count == 2)

        let state = try await harness.manager.install(try #require(licenses.first))
        #expect(state.isLicensed)
    }

    // MARK: - Text form

    @Test("The base64 text form round-trips through whitespace a mail client adds")
    func textFormSurvivesMangling() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)
        let text = try harness.factory.text(for: .perpetual)

        // A mail client will wrap, indent, and add blank lines.
        let mangled = "  \n" + text.replacingOccurrences(of: "\n", with: "\n   ") + "\n\n"

        let licenses = try harness.reader.read(base64Text: mangled)
        let state = try await harness.manager.install(try #require(licenses.first))

        #expect(state.isLicensed)
    }

    // MARK: - Version bounds

    @Test("A perpetual fallback refuses a version past its ceiling")
    func versionCeilingIsEnforced() async throws {
        let harness = try DemoHarness(signaturePolicy: .required, applicationVersion: "2.0.0")

        do {
            _ = try await harness.manager.installLicenseFile(
                try harness.factory.file(for: .versionCeiling),
                reader: harness.reader
            )
            Issue.record("expected the version bound to be enforced")
        } catch LicenseKitError.validation(let report) {
            #expect(report.hasFailure {
                if case .versionNotCovered = $0 { return true }; return false
            })
        }
    }

    @Test("The same license is accepted by a version the customer paid for")
    func versionCeilingAllowsCoveredVersions() async throws {
        let harness = try DemoHarness(signaturePolicy: .required, applicationVersion: "1.8.0")

        let state = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .versionCeiling),
            reader: harness.reader
        )

        // The customer keeps the versions they own; only upgrades need a renewal.
        #expect(state.isLicensed)
    }

    @Test("With no application version the bound cannot be checked and is skipped")
    func versionBoundIsSkippedWithoutAVersion() async throws {
        let harness = try DemoHarness(signaturePolicy: .required, applicationVersion: nil)

        let state = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .versionCeiling),
            reader: harness.reader
        )

        #expect(state.isLicensed)
        // Recorded as "nothing to check", not as a pass.
        #expect(state.report?.notApplicable.contains(.versionBound) == true)
    }

    // MARK: - Signature policy

    @Test("Disabling signature checking lets a tampered license through")
    func disablingSignaturesIsDangerous() async throws {
        let harness = try DemoHarness(signaturePolicy: .disabled)

        let state = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .tampered),
            reader: harness.reader
        )

        // This is the reason the Setup screen marks it as never shippable: the
        // forged entitlement is now honoured.
        #expect(state.isLicensed)
        #expect(state.isEntitled(to: EntitlementID(rawValue: "everything.forever")))
    }
}
