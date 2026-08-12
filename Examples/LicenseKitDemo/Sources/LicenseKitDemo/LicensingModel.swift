import DemoBackstage
import Foundation
import LicenseKit
import Observation

/// The app's licensing view model.
///
/// One of these exists for the whole app, and it is the only thing the views
/// talk to. The shape worth copying is the middle section: every operation runs
/// through ``perform(_:_:)``, which owns the loading flag and the error
/// presentation, so no screen has to remember to do either.
///
/// State arrives by *subscription*, not by return value. `activate` and
/// `refresh` do return the new state, but the source of truth is
/// `LicenseManager.stateUpdates()` — otherwise a background refresh that changes
/// the state would leave the UI showing a stale answer.
@MainActor
@Observable
final class LicensingModel {
    // MARK: Published state

    /// The single value the UI branches on.
    private(set) var state: LicenseState = .unlicensed

    private(set) var runtime: DemoRuntime

    /// True while a licensing call is in flight. Screens disable their controls
    /// on this rather than tracking their own flags.
    private(set) var isBusy = false
    private(set) var busyLabel = ""

    /// The result of the most recent operation, success or failure.
    private(set) var outcome: DemoOutcome?

    private(set) var activity: [ActivityEntry] = []

    // The service's own state, mirrored for the Service screen.
    private(set) var accounts: [DemoStoreBackend.Account] = []
    private(set) var serviceCondition: DemoStoreBackend.Condition = .healthy
    private(set) var serviceSignsLicenses = true

    /// Edited freely by the Setup screen, then committed with ``applySetup()``.
    /// Kept apart from `runtime.setup` so the screen can show an Apply button
    /// and the user can see what is pending.
    var draftSetup: DemoSetup

    var keyEntry: String = ""
    var pastedLicense: String = ""

    /// Whether the pending edits differ from what is actually running.
    var hasPendingSetupChanges: Bool { draftSetup != runtime.setup }

    // MARK: Collaborators

    /// Shared across rebuilds so time travel and the service's memory survive a
    /// configuration change.
    let clock = AdjustableClock()
    private let backend: DemoStoreBackend
    private let memoryStore = InMemoryLicenseStore()
    private let recorder = ActivityRecorder()

    private var observation: Task<Void, Never>?

    init() {
        let clock = self.clock
        let recorder = self.recorder
        let backend = DemoStoreBackend(clock: clock, log: recorder.serviceSink)
        self.backend = backend

        let setup = DemoSetup()
        self.draftSetup = setup
        self.runtime = DemoRuntime.make(
            setup: setup,
            clock: clock,
            backend: backend,
            memoryStore: memoryStore,
            recorder: recorder
        )
    }

    // MARK: - Lifecycle

    /// Called once when the window appears.
    func begin() async {
        drainActivity()
        observe()
        await reportRuntimeNotes()
        await start()
        await refreshServiceMirror()
    }

    /// Loads whatever was stored, validates it, and optionally refreshes.
    ///
    /// This is the launch path, and it never throws — an app that crashes because
    /// its licensing store is corrupt is worse than one that reports itself
    /// unlicensed and offers a way back in.
    func start() async {
        isBusy = true
        busyLabel = "Restoring"
        let restored = await runtime.manager.start()
        isBusy = false

        switch restored {
        case .unlicensed:
            recorder.app("start() found no stored license")
        case .licensed:
            recorder.app("start() restored a valid license from \(runtime.storeDescription)")
        case .invalid(_, let report):
            recorder.app("start() restored a license that no longer validates: \(report.summary)", level: .notice)
        }
    }

    /// Rebuilds the runtime around the edited setup.
    ///
    /// A real app does this once at launch. Doing it live is what lets the demo
    /// show that the *same* stored license is accepted or rejected depending on
    /// how the host configured verification — the license never changed.
    func applySetup() async {
        let previous = runtime.setup
        runtime = DemoRuntime.make(
            setup: draftSetup,
            clock: clock,
            backend: backend,
            memoryStore: memoryStore,
            recorder: recorder
        )
        recorder.app("configuration rebuilt")
        await reportRuntimeNotes()

        observe()
        await start()

        if previous.storeKind != draftSetup.storeKind {
            outcome = DemoOutcome.success(
                "Configuration applied",
                "Records now come from \(runtime.storeDescription). A license saved "
                    + "under the previous store is still there, but this store has "
                    + "its own contents."
            )
        } else {
            outcome = DemoOutcome.success(
                "Configuration applied",
                "The stored license was re-read and re-validated against the new rules."
            )
        }
    }

    func revertSetup() {
        draftSetup = runtime.setup
    }

    private func reportRuntimeNotes() async {
        for note in runtime.notes {
            recorder.app(note, level: .notice)
        }
        if let first = runtime.notes.first {
            outcome = DemoOutcome(
                kind: .warning,
                title: "The licensing layer started in a degraded state",
                message: first,
                hint: runtime.notes.count > 1 ? "See Activity for \(runtime.notes.count - 1) more." : nil
            )
        }
    }

    /// Mirrors `LicenseState` into the view layer.
    ///
    /// The stream yields the current state immediately on subscription, so there
    /// is no window where the UI shows a default it has to correct.
    private func observe() {
        observation?.cancel()
        let manager = runtime.manager
        observation = Task { [weak self] in
            for await update in await manager.stateUpdates() {
                guard let self else { return }
                self.state = update
            }
        }
    }

    private func drainActivity() {
        let stream = recorder.stream
        Task { [weak self] in
            for await entry in stream {
                guard let self else { return }
                self.activity.append(entry)
                // Bound the array so a long session cannot grow the view's data
                // set without limit.
                if self.activity.count > 600 {
                    self.activity.removeFirst(self.activity.count - 600)
                }
            }
        }
    }

    // MARK: - Operations

    /// Runs one licensing call with a loading flag and uniform error handling.
    ///
    /// Every screen goes through here, which is why none of them contain a
    /// `do/catch`. `LicenseKitError` already carries user-facing text; `DemoOutcome`
    /// adds the remedy that goes with the structured reason.
    private func perform(
        _ label: String,
        _ body: () async throws -> DemoOutcome?
    ) async {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = label
        outcome = nil
        recorder.app("\(label)…")

        do {
            if let result = try await body() {
                outcome = result
            }
        } catch {
            let failure = DemoOutcome(error, operation: label)
            outcome = failure
            recorder.app("\(label) failed: \(failure.message)", level: .error)
        }

        isBusy = false
        busyLabel = ""
        await refreshServiceMirror()
    }

    /// Redeems a key against the provider.
    func activate() async {
        let key = LicenseKey(keyEntry)
        // No trimming or upper-casing here on purpose: `LicenseKey` normalises
        // itself, so "apert-studio-perpetual" and "APERTSTUDIOPERPETUAL" are the
        // same key. Doing it by hand in the UI would be duplicated logic that
        // eventually disagrees.
        guard !key.normalized.isEmpty else {
            outcome = DemoOutcome(
                kind: .warning,
                title: "Enter a key",
                message: "Pick one of the keys below, or type your own to see a rejection.",
                hint: nil
            )
            return
        }

        await perform("Activation") {
            let result = try await runtime.manager.activate(key: key)
            // Reaching a non-licensed state here would mean `activate` returned
            // rather than threw, which it does not do — it throws
            // `.validation(_:)` instead, precisely so a rejected license is never
            // mistaken for a successful activation. Handled anyway rather than
            // force-unwrapped.
            guard case .licensed(let record, let report) = result else {
                return DemoOutcome(
                    kind: .failure,
                    title: "Activation returned a license this app rejects",
                    message: result.localizedSummary,
                    hint: nil
                )
            }
            return DemoOutcome(
                kind: report.warnings.isEmpty ? .success : .warning,
                title: "Activated",
                message: report.warnings.isEmpty
                    ? "\(record.license.product.name ?? "The product") is licensed on this Mac."
                    : report.summary,
                hint: record.activation?.deviceName.map { "Seat claimed as \($0)." }
            )
        }
    }

    /// Releases this Mac's seat and forgets the license.
    ///
    /// Worth reading `LicenseManager.deactivate()` alongside this: the local
    /// record is removed even when the provider call fails, then the error is
    /// rethrown. A user who asked to sign out must end up signed out.
    func deactivate() async {
        await perform("Deactivation") {
            try await runtime.manager.deactivate()
            return DemoOutcome.success(
                "Deactivated",
                "The seat was released and the local record removed."
            )
        }
    }

    /// Forgets the license locally without telling the provider.
    ///
    /// The seat stays claimed upstream, which is exactly what happens when a Mac
    /// is wiped or sold. Recovering it needs seat reclamation or a support tool.
    func removeLicense() async {
        await perform("Removal") {
            try await runtime.manager.removeLicense()
            return DemoOutcome(
                kind: .warning,
                title: "Removed locally",
                message: "The record is gone from this Mac, but the seat is still "
                    + "claimed on the service.",
                hint: "This is the lost-or-wiped-device case. Check the seat count "
                    + "on the Service screen."
            )
        }
    }

    /// Re-checks the license against its provider.
    func refresh() async {
        await perform("Refresh") {
            let result = try await runtime.manager.refresh()
            switch result {
            case .licensed(_, let report):
                return DemoOutcome(
                    kind: report.warnings.isEmpty ? .success : .warning,
                    title: "Refreshed",
                    message: report.warnings.isEmpty
                        ? "The provider confirmed the license."
                        : report.summary,
                    hint: nil
                )
            case .invalid(_, let report):
                // Reached without throwing: the provider answered clearly and the
                // answer was bad news. A revoked license lands here.
                return DemoOutcome(
                    kind: .failure,
                    title: "The provider's answer invalidated the license",
                    message: report.summary,
                    hint: report.failures.first.map { Remedy(for: $0).explanation }
                )
            case .unlicensed:
                return DemoOutcome(kind: .warning, title: "Nothing installed", message: "", hint: nil)
            }
        }
    }

    /// Re-runs the rule chain locally, with no network call.
    ///
    /// The cheap operation the demo leans on after travelling in time or changing
    /// a policy: nothing about the license changes, only the verdict.
    func revalidate() async {
        await perform("Revalidation") {
            let result = await runtime.manager.revalidate()
            switch result {
            case .licensed(_, let report):
                return DemoOutcome(
                    kind: report.warnings.isEmpty ? .success : .warning,
                    title: "Still valid",
                    message: report.warnings.isEmpty ? "Every rule passed." : report.summary,
                    hint: nil
                )
            case .invalid(_, let report):
                return DemoOutcome(
                    kind: .failure,
                    title: "Now rejected",
                    message: report.summary,
                    hint: report.failures.first.map { Remedy(for: $0).explanation }
                )
            case .unlicensed:
                return DemoOutcome(
                    kind: .warning,
                    title: "Nothing to validate",
                    message: "No license is installed.",
                    hint: nil
                )
            }
        }
    }

    // MARK: - Offline license files

    /// Installs one of the minted license files.
    func install(_ scenario: OfflineScenario) async {
        await perform("Installing \(scenario.rawValue)") {
            let data = try runtime.factory.file(for: scenario)

            // A bundle holds more than one license, and `installLicenseFile`
            // deliberately refuses it rather than silently picking one. Reading
            // it properly takes the multi-license path.
            if scenario == .bundle {
                let licenses = try runtime.fileReader.read(data)
                return DemoOutcome(
                    kind: .warning,
                    title: "That file holds \(licenses.count) licenses",
                    message: "installLicenseFile(_:) handles exactly one. "
                        + "LicenseFileReader.read(_:) returned all "
                        + "\(licenses.count) so the app can choose.",
                    hint: "Use “Install first seat” to install one of them."
                )
            }

            let result = try await runtime.manager.installLicenseFile(
                data,
                reader: runtime.fileReader
            )
            guard case .licensed(_, let report) = result else {
                return DemoOutcome(kind: .failure, title: "Rejected", message: result.localizedSummary, hint: nil)
            }
            return DemoOutcome(
                kind: report.warnings.isEmpty ? .success : .warning,
                title: "Installed",
                message: report.warnings.isEmpty ? "Every rule passed." : report.summary,
                hint: nil
            )
        }
    }

    /// Installs one license out of a multi-license container.
    func installFirstFromBundle() async {
        await perform("Installing one seat from the bundle") {
            let data = try runtime.factory.file(for: .bundle)
            let licenses = try runtime.fileReader.read(data)
            guard let first = licenses.first else {
                return DemoOutcome(kind: .failure, title: "Empty container", message: "", hint: nil)
            }
            _ = try await runtime.manager.install(first)
            return DemoOutcome.success(
                "Installed one seat",
                "Took \(first.license.subject.name ?? "the first license") out of "
                    + "\(licenses.count) and installed it with install(_:)."
            )
        }
    }

    /// Installs a license the user pasted as text.
    func installPastedLicense() async {
        let text = pastedLicense
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            outcome = DemoOutcome(
                kind: .warning,
                title: "Nothing pasted",
                message: "Copy a license from the list first.",
                hint: nil
            )
            return
        }

        await perform("Installing pasted license") {
            // The reader tolerates the line wrapping and stray whitespace a mail
            // client will add, so the customer can paste straight from an email.
            let licenses = try runtime.fileReader.read(base64Text: text)
            guard let first = licenses.first else {
                return DemoOutcome(kind: .failure, title: "Empty license", message: "", hint: nil)
            }
            _ = try await runtime.manager.install(first)
            return DemoOutcome.success("Installed", "The pasted license validated and was stored.")
        }
    }

    /// Installs a license file the user chose from disk.
    func installFile(at url: URL) async {
        await perform("Installing \(url.lastPathComponent)") {
            // `read(contentsOf:)` accepts the binary container or its base64 text
            // form, so a customer who saved the email body as a file still works.
            let licenses = try runtime.fileReader.read(contentsOf: url)
            guard let first = licenses.first else {
                return DemoOutcome(kind: .failure, title: "Empty license file", message: "", hint: nil)
            }
            _ = try await runtime.manager.install(first)
            return DemoOutcome.success(
                "Installed",
                licenses.count > 1
                    ? "The file held \(licenses.count) licenses; the first was installed."
                    : "\(url.lastPathComponent) validated and was stored."
            )
        }
    }

    /// The base64 text form of a scenario, as a customer would receive it.
    func text(for scenario: OfflineScenario) -> String? {
        do {
            return try runtime.factory.text(for: scenario)
        } catch {
            outcome = DemoOutcome(error, operation: "Rendering the license")
            return nil
        }
    }

    func fileData(for scenario: OfflineScenario) -> Data? {
        do {
            return try runtime.factory.file(for: scenario)
        } catch {
            outcome = DemoOutcome(error, operation: "Writing the license")
            return nil
        }
    }

    func suggestedFilename(for scenario: OfflineScenario) -> String {
        runtime.factory.suggestedFilename(for: scenario)
    }

    // MARK: - Time travel

    /// Moves the clock and immediately re-runs the rules.
    ///
    /// Every date decision in the SDK goes through `LicenseClock`, so this is all
    /// it takes to watch a subscription cross into its warning window, then its
    /// grace period, then expiry.
    func travel(days: Double) async {
        clock.travel(days: days)
        recorder.app("clock moved \(days > 0 ? "forward" : "back") "
            + "\(DemoFormat.duration(.licenseDays(days))) (offset now "
            + "\(DemoFormat.duration(clock.offset)))")
        await revalidate()
    }

    func resetClock() async {
        clock.reset()
        recorder.app("clock reset to the system time")
        await revalidate()
    }

    // MARK: - The service

    private func refreshServiceMirror() async {
        accounts = await backend.allAccounts()
        serviceCondition = await backend.currentCondition()
        serviceSignsLicenses = await backend.issuesSignedLicenses()
    }

    func setServiceCondition(_ condition: DemoStoreBackend.Condition) async {
        await backend.setCondition(condition)
        await refreshServiceMirror()
    }

    func setServiceSignsLicenses(_ signs: Bool) async {
        await backend.setIssuesSignedLicenses(signs)
        await refreshServiceMirror()
    }

    func revoke(_ key: String) async {
        await backend.revoke(key)
        await refreshServiceMirror()
    }

    func reinstate(_ key: String) async {
        await backend.reinstate(key)
        await refreshServiceMirror()
    }

    func renew(_ key: String) async {
        await backend.renew(key, byDays: 30)
        await refreshServiceMirror()
    }

    func lapse(_ key: String) async {
        await backend.lapse(key)
        await refreshServiceMirror()
    }

    func occupySeat(on key: String) async {
        await backend.occupySeat(on: key)
        await refreshServiceMirror()
    }

    func releaseSeats(on key: String) async {
        await backend.releaseAllSeats(on: key)
        await refreshServiceMirror()
    }

    func resetService() async {
        await backend.reset()
        await refreshServiceMirror()
        outcome = DemoOutcome.success(
            "Service reset",
            "Accounts, seats, and the failure mode are back to their seeded values."
        )
    }

    func clearActivity() {
        activity.removeAll()
    }

    // MARK: - Derived, for the views

    /// Whether a capability is available right now.
    ///
    /// This answers `false` for an invalid or absent license without the caller
    /// having to check `isLicensed` first — the failure mode of a forgotten check
    /// is a paywall bypass, so the safe answer is the built-in one.
    func isEntitled(to entitlement: EntitlementID) -> Bool {
        state.isEntitled(to: entitlement)
    }

    func limit(for entitlement: EntitlementID) -> Int? {
        state.limit(for: entitlement)
    }

    var canDeactivate: Bool {
        runtime.supportsDeactivation(for: state.record)
    }

    /// The fingerprint this build reports, for the Status screen.
    ///
    /// Salted and hashed, which is the point: it can be handed to a provider for
    /// seat accounting without disclosing anything that could be correlated with
    /// another vendor's fingerprint for the same Mac.
    func currentFingerprint() async -> String {
        guard let record = state.record, let activation = record.activation else {
            return "not activated on this Mac"
        }
        return activation.fingerprint.rawValue
    }
}
