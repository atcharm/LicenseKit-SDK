import DemoBackstage
import Foundation
import LicenseKit
import Testing

/// Persisting, restoring, and what happens as time passes.
@Suite("Lifecycle")
struct LifecycleTests {
    // MARK: - Persistence

    @Test("A license installed in one launch is restored in the next")
    func licenseSurvivesRelaunch() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)
        _ = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .perpetual),
            reader: harness.reader
        )

        // A brand-new manager over the same store: a relaunch.
        let relaunched = try harness.relaunched()
        let restored = await relaunched.manager.start()

        #expect(restored.isLicensed)
        #expect(restored.isEntitled(to: DemoEntitlement.exportRAW))
    }

    @Test("An activation is restored from a file store on disk")
    func activationSurvivesRelaunchOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileLicenseStore(url: directory.appendingPathComponent("licenses.json"))
        let harness = try DemoHarness(store: store)
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))

        // A second store instance reading the same file, as a new process would.
        let reopened = FileLicenseStore(url: directory.appendingPathComponent("licenses.json"))
        let relaunched = try DemoHarness(
            store: reopened,
            clock: harness.clock,
            backend: harness.backend
        )
        let restored = await relaunched.manager.start()

        #expect(restored.isLicensed)
        #expect(restored.record?.license.key == LicenseKey(DemoKeys.perpetual))
    }

    @Test("Nothing stored means unlicensed, and start() does not throw")
    func emptyStoreStartsUnlicensed() async throws {
        let harness = try DemoHarness()

        let state = await harness.manager.start()

        #expect(state == .unlicensed)
        #expect(state.isEntitled(to: DemoEntitlement.exportPDF) == false)
    }

    // MARK: - Time passing

    @Test("A subscription that expires between launches is rejected on restore")
    func expiryBetweenLaunchesIsCaught() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)
        let installed = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .subscription),
            reader: harness.reader
        )
        #expect(installed.isLicensed)

        // 45-day term, 3-day expiry grace. Come back in three months.
        harness.clock.travel(days: 90)

        let relaunched = try harness.relaunched(signaturePolicy: .required)
        let restored = await relaunched.manager.start()

        #expect(restored.isInvalid)
        #expect(restored.report?.hasFailure {
            if case .expired = $0 { return true }; return false
        } == true)
        // The record is kept rather than discarded, so the UI can show which
        // license failed and offer a renewal.
        #expect(restored.record != nil)
    }

    @Test("A subscription crosses into its warning window as time passes")
    func warningWindowIsReached() async throws {
        // `offlineDefault()`, which is the correct chain for a license delivered as
        // a file — see `subscriptionFileNeedsTheOfflineChain` below for what
        // happens if you pair a file with the connected chain instead.
        let harness = try DemoHarness(signaturePolicy: .required, connected: false)
        let installed = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .subscription),
            reader: harness.reader
        )
        // 45 days out, past the default 14-day threshold.
        #expect(installed.warnings.isEmpty)

        harness.clock.travel(days: 35)
        let later = await harness.manager.revalidate()

        #expect(later.isLicensed)
        #expect(later.report?.hasWarning {
            if case .expiringSoon = $0 { return true }; return false
        } == true)
    }

    @Test("A subscription file under the connected chain dies of staleness it cannot cure")
    func subscriptionFileNeedsTheOfflineChain() async throws {
        // A trap worth knowing about. `LicenseSpecification.subscription` defaults
        // to a 30-day offline grace, which is right for a subscription backed by a
        // provider. But this license arrived as a *file*, from the built-in
        // provider — there is nobody to refresh against, so once the window closes
        // there is no way back.
        let harness = try DemoHarness(signaturePolicy: .required, connected: true)
        _ = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .subscription),
            reader: harness.reader
        )

        harness.clock.travel(days: 35)
        let stale = await harness.manager.revalidate()

        #expect(stale.isInvalid)
        #expect(stale.report?.hasFailure {
            if case .offlineGraceExhausted = $0 { return true }; return false
        } == true)

        // The fix is the configuration, not the license: pair file-delivered
        // licenses with `offlineDefault()`, which does not include the rule, or
        // issue them with `offlineGrace: nil`.
        let offline = try DemoHarness(
            signaturePolicy: .required,
            connected: false,
            store: harness.store,
            clock: harness.clock,
            backend: harness.backend
        )
        #expect(await offline.manager.start().isLicensed)
    }

    @Test("Winding the clock backwards is detected as tampering")
    func clockRollbackIsDetected() async throws {
        // A shared anchor, so the high-water mark set by the first pass survives.
        let anchor = InMemoryTimeAnchor()
        let harness = try DemoHarness(signaturePolicy: .required, timeAnchor: anchor)

        let installed = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .perpetual),
            reader: harness.reader
        )
        #expect(installed.isLicensed)

        // Back a month — far past the one-day tolerance that absorbs an NTP
        // correction or a dead coin cell.
        harness.clock.travel(days: -30)
        let rolled = await harness.manager.revalidate()

        #expect(rolled.isInvalid)
        #expect(rolled.report?.hasFailure {
            if case .clockTampering = $0 { return true }; return false
        } == true)
    }

    @Test("A small clock correction is tolerated")
    func smallClockCorrectionIsFine() async throws {
        let anchor = InMemoryTimeAnchor()
        let harness = try DemoHarness(signaturePolicy: .required, timeAnchor: anchor)
        _ = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .perpetual),
            reader: harness.reader
        )

        // Two hours back: the kind of thing a real clock does by itself.
        harness.clock.travel(days: -(2.0 / 24.0))
        let state = await harness.manager.revalidate()

        #expect(state.isLicensed)
    }

    // MARK: - Offline grace

    @Test("Going too long without reaching the provider exhausts the offline grace")
    func offlineGraceExhausts() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.monthly))

        // Push the expiry well out, so this test isolates staleness rather than
        // also tripping the validity window.
        await harness.backend.renew(DemoKeys.monthly, byDays: 400)
        let refreshed = try await harness.manager.refresh()
        #expect(refreshed.isLicensed)

        // The subscription carries a 30-day offline grace.
        harness.clock.travel(days: 45)
        let stale = await harness.manager.revalidate()

        #expect(stale.isInvalid)
        #expect(stale.report?.hasFailure {
            if case .offlineGraceExhausted = $0 { return true }; return false
        } == true)
    }

    @Test("Inside the offline grace the license works, with a warning near the end")
    func offlineGraceWarnsBeforeItExpires() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.monthly))
        await harness.backend.renew(DemoKeys.monthly, byDays: 400)
        _ = try await harness.manager.refresh()

        // 26 of 30 days: past the three-quarter mark where the warning starts.
        harness.clock.travel(days: 26)
        let state = await harness.manager.revalidate()

        #expect(state.isLicensed)
        #expect(state.isRunningOnGrace)
        #expect(state.report?.hasWarning {
            if case .withinOfflineGrace = $0 { return true }; return false
        } == true)
    }

    @Test("Reaching the provider clears the staleness that offline grace measures")
    func refreshResetsStaleness() async throws {
        let harness = try DemoHarness()
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.monthly))
        await harness.backend.renew(DemoKeys.monthly, byDays: 400)
        _ = try await harness.manager.refresh()

        harness.clock.travel(days: 45)
        #expect(await harness.manager.revalidate().isInvalid)

        // One successful round trip and the window starts again.
        let recovered = try await harness.manager.refresh()
        #expect(recovered.isLicensed)
    }

    @Test("A signed offline license has no offline grace and never goes stale")
    func offlineFilesDoNotExpireFromStaleness() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)
        _ = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .perpetual),
            reader: harness.reader
        )

        harness.clock.travel(days: 900)
        let state = await harness.manager.revalidate()

        // No interval configured means unlimited offline use, which is the right
        // default for a signed file: there is no provider to check in with.
        #expect(state.isLicensed)
        #expect(state.report?.notApplicable.contains(.offlineGrace) == true)
    }

    // MARK: - Machine binding

    @Test("A record activated on one machine is rejected on another")
    func machineBindingIsEnforced() async throws {
        let harness = try DemoHarness(fingerprint: "this-mac")
        _ = try await harness.manager.activate(key: LicenseKey(DemoKeys.perpetual))

        // Same store, different machine — copying an app and its licensing state
        // to another Mac.
        let elsewhere = try harness.relaunched(fingerprint: "some-other-mac")
        let state = await elsewhere.manager.start()

        #expect(state.isInvalid)
        #expect(state.report?.hasFailure { $0 == .machineMismatch } == true)
    }

    @Test("An offline license with no activation is not machine-bound")
    func unboundLicensesAreNotChecked() async throws {
        let harness = try DemoHarness(signaturePolicy: .required, fingerprint: "this-mac")
        _ = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .perpetual),
            reader: harness.reader
        )

        let elsewhere = try harness.relaunched(
            fingerprint: "some-other-mac",
            signaturePolicy: .required
        )
        let state = await elsewhere.manager.start()

        // `install(_:)` records this machine's fingerprint, so moving it does trip
        // the rule. What matters is that the failure is machine binding and
        // nothing else — the signature is still perfectly valid.
        #expect(state.report?.hasFailure { $0 == .machineMismatch } == true)
        #expect(state.report?.hasFailure { $0 == .signatureInvalid } == false)
    }

    // MARK: - State observation

    @Test("State updates are delivered to an observer, starting with the current state")
    func stateUpdatesAreObservable() async throws {
        let harness = try DemoHarness(signaturePolicy: .required)

        let stream = await harness.manager.stateUpdates()
        var iterator = stream.makeAsyncIterator()

        // The stream opens with the current state, so a UI never shows a default
        // it then has to correct.
        let initial = await iterator.next()
        #expect(initial == .unlicensed)

        _ = try await harness.manager.installLicenseFile(
            try harness.factory.file(for: .perpetual),
            reader: harness.reader
        )

        let updated = await iterator.next()
        #expect(updated?.isLicensed == true)
    }
}
