import DemoBackstage
import Foundation
import LicenseKit
import Testing

/// Activation, refresh, seats, and every way the service can fail.
@Suite("Provider flows")
struct ProviderFlowTests {
    // MARK: - The happy path

    @Test("Activating a known key produces a licensed state with its entitlements")
    func activateSucceeds() async throws {
        let harness = try DemoHarness()

        let state = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))

        #expect(state.isLicensed)
        #expect(state.warnings.isEmpty)
        #expect(state.isEntitled(to: DemoEntitlement.exportPDF))
        #expect(state.isEntitled(to: DemoEntitlement.exportRAW))
        // A granted capability can carry a numeric ceiling.
        #expect(state.limit(for: DemoEntitlement.cloudSync) == 3)
        // The signed license arrived with a signature the app trusts.
        #expect(state.record?.signature?.keyID == KeyIdentifier(rawValue: DemoVendorKeys.keyID))
    }

    @Test("Activation claims exactly one seat")
    func activationClaimsASeat() async throws {
        let harness = try DemoHarness()

        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.solo))

        let account = await harness.backend.account(matching: DemoKeys.solo)
        #expect(account?.seatsUsed == 1)
    }

    @Test("A key the service does not know is reported as not found, not as a server fault")
    func unknownKeyIsNotFound() async throws {
        let harness = try DemoHarness()

        await #expect(throws: LicenseKitError.self) {
            try await harness.manager.activate(key: "NOPE-NOPE-NOPE-NOPE")
        }

        do {
            _ = try await harness.manager.activate(key: "NOPE-NOPE-NOPE-NOPE")
            Issue.record("expected activation to throw")
        } catch LicenseKitError.provider(let error) {
            #expect(error == .licenseNotFound)
            // Definitive: retrying a key that does not exist cannot help.
            #expect(error.isTransient == false)
        }
    }

    // MARK: - Definitive rejections

    @Test("A refunded purchase is refused, even though the service answers HTTP 200")
    func refundedPurchaseIsRefused() async throws {
        let harness = try DemoHarness()

        do {
            _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.refunded))
            Issue.record("expected a refunded purchase to be refused")
        } catch LicenseKitError.provider(let error) {
            guard case .rejected = error else {
                Issue.record("expected .rejected, got \(error)")
                return
            }
            #expect(error.isTransient == false)
        }

        // Nothing was stored: a license the app would reject must not be persisted.
        #expect(try await harness.store.loadAll().isEmpty)
    }

    @Test("Reaching the seat ceiling is reported as a seat limit, not a generic rejection")
    func seatLimitIsReported() async throws {
        let harness = try DemoHarness()
        // The solo account has exactly one seat, and another machine took it.
        await harness.backend.occupySeat(on: DemoKeys.solo)

        do {
            _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.solo))
            Issue.record("expected the seat limit to be enforced")
        } catch LicenseKitError.provider(let error) {
            #expect(error == .seatLimitReached)
        }
    }

    @Test("An unauthorized app is a definitive failure and is not retried")
    func unauthorizedIsDefinitive() async throws {
        let harness = try DemoHarness()
        await harness.backend.setCondition(.unauthorized)

        do {
            _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))
            Issue.record("expected activation to throw")
        } catch LicenseKitError.provider(let error) {
            #expect(error == .unauthorized)
            #expect(error.isTransient == false)
        }
    }

    @Test("A body the adapter cannot read is a malformed response, not a success")
    func malformedResponseIsCaught() async throws {
        let harness = try DemoHarness()
        await harness.backend.setCondition(.malformed)

        do {
            _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))
            Issue.record("expected activation to throw")
        } catch LicenseKitError.provider(let error) {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    // MARK: - Transient failures

    @Test("A transient 503 is absorbed by the retry policy and never reaches the app")
    func flakyServiceIsRetried() async throws {
        let harness = try DemoHarness()
        // The first attempt of each operation fails; the provider retries.
        await harness.backend.setCondition(.flaky)

        let state = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))
        #expect(state.isLicensed)
    }

    @Test("Rate limiting is retried, then reported once the budget is spent")
    func rateLimitingIsEventuallyReported() async throws {
        // No retries, so the test does not spend two seconds honouring Retry-After.
        let harness = try DemoHarness(maximumRetries: 0)
        await harness.backend.setCondition(.rateLimited)

        do {
            _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))
            Issue.record("expected activation to throw")
        } catch LicenseKitError.provider(let error) {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
            // The adapter passed the server's own Retry-After through.
            #expect(retryAfter == 1)
            #expect(error.isTransient)
        }
    }

    @Test("A network failure during refresh does not revoke a paying customer's license")
    func transientRefreshFailureKeepsTheLicense() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.monthly))

        await harness.backend.setCondition(.unreachable)

        // `refresh()` deliberately does not throw for a transient failure: the
        // customer's network is not the customer's fault.
        let state = try await harness.manager.refresh()

        #expect(state.isLicensed)
        #expect(state.isEntitled(to: DemoEntitlement.exportRAW))
    }

    // MARK: - Provider-side changes

    @Test("Revoking upstream invalidates the license on the next refresh")
    func revocationTakesEffectOnRefresh() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.monthly))

        await harness.backend.revoke(DemoKeys.monthly)

        // Refresh does not throw here: the provider answered clearly, and the
        // answer changed the record's local state. The rules then reject it.
        let state = try await harness.manager.refresh()

        #expect(state.isInvalid)
        #expect(state.report?.hasFailure { $0 == .revoked } == true)
        #expect(state.isEntitled(to: DemoEntitlement.exportPDF) == false)
    }

    @Test("A lapsed subscription reads as expired rather than revoked")
    func lapsedSubscriptionIsExpired() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.monthly))

        await harness.backend.lapse(DemoKeys.monthly)
        let state = try await harness.manager.refresh()

        #expect(state.isInvalid)
        #expect(state.report?.hasFailure { if case .expired = $0 { return true }; return false } == true)
    }

    @Test("A renewal moves the effective expiry without reissuing or resigning")
    func renewalMovesExpiryWithoutReissue() async throws {
        let harness = try DemoHarness()
        let activated = try await harness.manager.activate(key: LicenseKey(DemoKeys.monthly))
        let signedTerm = activated.record?.license.policy.validity.expiresAt
        let signatureBefore = activated.record?.signature

        await harness.backend.renew(DemoKeys.monthly, byDays: 300)
        let refreshed = try await harness.manager.refresh()

        let record = try #require(refreshed.record)
        // The signed policy is untouched — it is covered by the signature, and a
        // renewal is not allowed to need a reissue.
        #expect(record.license.policy.validity.expiresAt == signedTerm)
        // Still the same signing key. (This stand-in service re-mints and re-signs
        // on every call, so the signature *bytes* differ; a real one would more
        // likely hand back what it stored. Either is fine — the point is that the
        // renewal did not have to touch the signed claim set.)
        #expect(record.signature?.keyID == signatureBefore?.keyID)
        // But the effective expiry moved, because the provider's assertion wins.
        let effective = try #require(record.effectiveExpiry)
        let signed = try #require(signedTerm)
        #expect(effective > signed)
        #expect(refreshed.isLicensed)
    }

    @Test("Seat usage above the ceiling invalidates the license on refresh")
    func seatOverageInvalidates() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.solo))

        // Two more machines take seats on a one-seat license.
        await harness.backend.occupySeat(on: DemoKeys.solo, deviceName: "Second Mac")
        await harness.backend.occupySeat(on: DemoKeys.solo, deviceName: "Third Mac")

        let state = try await harness.manager.refresh()

        #expect(state.isInvalid)
        #expect(state.report?.hasFailure {
            if case .seatLimitExceeded = $0 { return true }; return false
        } == true)
    }

    // MARK: - Deactivation

    @Test("Deactivating releases the seat and forgets the license")
    func deactivationReleasesTheSeat() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.solo))
        #expect(await harness.backend.account(matching: DemoKeys.solo)?.seatsUsed == 1)

        try await harness.manager.deactivate()

        #expect(await harness.backend.account(matching: DemoKeys.solo)?.seatsUsed == 0)
        #expect(await harness.manager.state == .unlicensed)
        #expect(try await harness.store.loadAll().isEmpty)
    }

    @Test("Removing locally leaves the seat claimed upstream — the wiped-device case")
    func removingLocallyStrandsTheSeat() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.solo))

        try await harness.manager.removeLicense()

        #expect(await harness.manager.state == .unlicensed)
        // Still claimed: this is why seat reclamation and a support tool matter.
        #expect(await harness.backend.account(matching: DemoKeys.solo)?.seatsUsed == 1)
    }

    @Test("Deactivating still clears the local record when the provider is unreachable")
    func deactivationIsLocalFirst() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.solo))

        await harness.backend.setCondition(.unreachable)

        // The error is rethrown so the app can mention the stranded seat, but a
        // user who asked to sign out must end up signed out regardless.
        await #expect(throws: LicenseKitError.self) {
            try await harness.manager.deactivate()
        }
        #expect(await harness.manager.state == .unlicensed)
    }

    // MARK: - Signatures from a provider

    @Test("An unsigned license from the service is rejected when signatures are required")
    func unsignedLicenseRejectedWhenRequired() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)
        await harness.backend.setIssuesSignedLicenses(false)

        do {
            _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))
            Issue.record("expected an unsigned license to be rejected")
        } catch LicenseKitError.validation(let report) {
            #expect(report.hasFailure { $0 == .signatureMissing })
        }
    }

    @Test("An unsigned license is accepted with a warning under requiredWhenPresent")
    func unsignedLicenseWarnsWhenTolerated() async throws {
        let harness = try DemoHarness(signaturePolicy: .requiredWhenPresent)
        await harness.backend.setIssuesSignedLicenses(false)

        let state = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))

        #expect(state.isLicensed)
        #expect(state.report?.hasWarning { $0 == .unsigned } == true)
    }
}
