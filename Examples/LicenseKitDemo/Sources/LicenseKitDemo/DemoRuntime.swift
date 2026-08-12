import DemoBackstage
import Foundation
import LicenseKit

// MARK: - Adjustable clock

/// A clock the demo can move, so expiry and grace can be observed rather than
/// waited for.
///
/// Every date decision in LicenseKit routes through `LicenseClock` rather than
/// calling `Date()`, which is what makes this possible at all. A real app ships
/// `SystemLicenseClock()`; a test suite ships `FixedLicenseClock(_:)`. This one
/// exists because a demo needs to jump forward 40 days between two button presses
/// and then come back.
///
/// `@unchecked Sendable` with a lock rather than an actor: `LicenseClock.now` is a
/// synchronous property, so the isolation has to be internal. The critical
/// section is a single `TimeInterval` read or write.
final class AdjustableClock: LicenseClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOffset: TimeInterval = 0

    /// Seconds added to the system clock. Negative moves time backwards, which is
    /// how the demo triggers `ClockTamperRule`.
    var offset: TimeInterval {
        get { lock.withLock { storedOffset } }
        set { lock.withLock { storedOffset = newValue } }
    }

    var now: Date { Date().addingTimeInterval(offset) }

    func travel(days: Double) {
        lock.withLock { storedOffset += .licenseDays(days) }
    }

    func reset() {
        lock.withLock { storedOffset = 0 }
    }
}

// MARK: - Setup

/// The configuration choices the demo exposes at runtime.
///
/// In a shipping app almost all of this is decided once and compiled in. It is
/// surfaced here because the choices are the interesting part of integrating
/// LicenseKit — each toggle below changes which rules run, what gets persisted,
/// or how strict verification is, and the Status screen shows the consequence
/// immediately.
struct DemoSetup: Equatable, Sendable {
    enum StoreKind: String, CaseIterable, Identifiable, Sendable {
        case file, keychain, memory
        var id: String { rawValue }

        var title: String {
            switch self {
            case .file: return "File"
            case .keychain: return "Keychain"
            case .memory: return "In memory"
            }
        }

        var detail: String {
            switch self {
            case .file:
                return "Application Support. The usual choice for a Mac app. "
                    + "Survives relaunch; removed when the user deletes the app."
            case .keychain:
                return "Survives a reinstall, and can be shared with an "
                    + "extension through an access group. Note that an unsigned "
                    + "binary — like this demo run from the command line — is "
                    + "often refused by the data-protection keychain."
            case .memory:
                return "Nothing is written to disk. Correct for tests, and for "
                    + "apps that re-activate against a provider on every launch."
            }
        }
    }

    enum SignaturePolicyChoice: String, CaseIterable, Identifiable, Sendable {
        case required, requiredWhenPresent, disabled
        var id: String { rawValue }

        var title: String {
            switch self {
            case .required: return "Required"
            case .requiredWhenPresent: return "When present"
            case .disabled: return "Disabled"
            }
        }

        var detail: String {
            switch self {
            case .required:
                return "Reject anything unsigned. Correct for offline license files."
            case .requiredWhenPresent:
                return "Verify a signature if there is one, and let an unsigned "
                    + "license through with a warning. Correct when licenses "
                    + "arrive from an authenticated API over TLS."
            case .disabled:
                return "Never check. Only for tests and previews — with this on, "
                    + "nothing distinguishes a real license from a typed text file."
            }
        }

        var policy: SignatureRule.Policy {
            switch self {
            case .required: return .required
            case .requiredWhenPresent: return .requiredWhenPresent
            case .disabled: return .disabled
            }
        }
    }

    enum ValidatorPreset: String, CaseIterable, Identifiable, Sendable {
        case offline, connected
        var id: String { rawValue }

        var title: String {
            switch self {
            case .offline: return "offlineDefault()"
            case .connected: return "connectedDefault()"
            }
        }

        var detail: String {
            switch self {
            case .offline:
                return "Signature, product, clock, validity, revocation, version "
                    + "bound, machine binding. No network expectations."
            case .connected:
                return "The offline chain plus seat accounting and the offline "
                    + "staleness check — the two rules that only mean something "
                    + "when a provider is involved."
            }
        }
    }

    var storeKind: StoreKind = .file
    var signaturePolicy: SignaturePolicyChoice = .requiredWhenPresent
    var validatorPreset: ValidatorPreset = .connected

    /// Parsed into a `SemanticVersion` for `VersionBoundRule`. Left empty, the
    /// rule reports itself not applicable, because this demo has no bundle to
    /// read `CFBundleShortVersionString` from.
    var applicationVersion: String = "2.0.0"

    var expiryWarningDays: Double = 14

    var enforcesMachineBinding = true
    var enforcesSeatLimit = true
    var detectsClockTampering = true

    /// When off, the runtime uses a fixed foreign fingerprint, so a record
    /// activated on this Mac trips `MachineBindingRule`.
    var identifiesAsThisMac = true

    /// Whether the clock-rollback high-water mark is kept in `UserDefaults`.
    var persistsTimeAnchor = true

    /// Whether the license-file reader carries the symmetric sealing key.
    var configuresSealingKey = true

    /// A host rule this demo's licenses deliberately fail, to show how a custom
    /// rule and a `.custom` failure reason surface.
    var enforcesSiteDomainRule = false

    var refreshesOnStart = true

    /// Zero so the demo can refresh repeatedly. A real app wants hours here.
    var minimumRefreshInterval: TimeInterval = 0
    var eagerRefreshDays: Double = 3

    var maximumRetries: Int = 2
}

// MARK: - Runtime

/// Everything the app needs, assembled from a `DemoSetup`.
///
/// This is the demo's answer to "where does LicenseKit get wired up?" — one
/// function, called at launch and again whenever a setting changes. The
/// interesting property is that nothing else in the app constructs a store, a
/// verifier, or a provider: they all come from here, so there is exactly one
/// place to look.
struct DemoRuntime: Sendable {
    let setup: DemoSetup
    let manager: LicenseManager
    let providers: [any LicenseProvider]
    let fileReader: LicenseFileReader
    let factory: DemoLicenseFactory

    /// The version `VersionBoundRule` will actually compare against, after
    /// parsing. `nil` means the rule cannot run.
    let resolvedApplicationVersion: SemanticVersion?

    /// A human-readable note about where records are being kept.
    let storeDescription: String

    /// Which rules the configured validator ended up with, for display.
    let activeRules: [RuleIdentifier]

    /// Anything that had to be degraded while assembling this runtime.
    ///
    /// Surfaced rather than thrown. A licensing layer that refuses to start
    /// leaves an app with no way to explain itself or to offer a re-activation
    /// button, which is strictly worse than starting up and reporting the
    /// problem — the same reasoning behind `LicenseManager.start()` never
    /// throwing.
    let notes: [String]

    /// Builds a runtime.
    ///
    /// - Parameters:
    ///   - clock: shared across rebuilds, so travelling in time survives a
    ///     configuration change.
    ///   - backend: the stand-in service, also shared. A local setting change must
    ///     not restart the vendor's server or forget that a license was revoked.
    ///   - memoryStore: shared for the same reason — switching the signature
    ///     policy should not silently discard an installed license.
    static func make(
        setup: DemoSetup,
        clock: AdjustableClock,
        backend: DemoStoreBackend,
        memoryStore: InMemoryLicenseStore,
        recorder: ActivityRecorder
    ) -> DemoRuntime {
        var notes: [String] = []

        // 1. Where records live between launches.
        let store: any LicenseStore
        let storeDescription: String
        switch setup.storeKind {
        case .file:
            // Only the directory lookup can fail here; a missing file is a
            // legitimate "no license yet" and reads as an empty store.
            if let fileStore = try? FileLicenseStore.applicationSupport(
                subdirectory: DemoProduct.bundleIdentifier
            ) {
                store = fileStore
                storeDescription = "~/Library/Application Support/"
                    + "\(DemoProduct.bundleIdentifier)/licenses.json"
            } else {
                store = memoryStore
                storeDescription = "process memory only (the file store was unavailable)"
                notes.append("Application Support could not be reached; using the in-memory store.")
            }
        case .keychain:
            store = KeychainLicenseStore(
                service: DemoProduct.bundleIdentifier,
                account: "licensekit.records",
                accessibility: .afterFirstUnlock
            )
            storeDescription = "keychain, service '\(DemoProduct.bundleIdentifier)'"
        case .memory:
            store = memoryStore
            storeDescription = "process memory only"
        }

        // 2. The trust anchor. Everything else is defence in depth; this is the
        //    part that establishes a vendor actually issued the license.
        //
        //    Note the fallback: a host that fails to configure keys gets
        //    `RejectingVerifier`, which accepts nothing. Failing closed is the
        //    only safe direction for a verification step — the alternative is a
        //    silent paywall bypass.
        let verifier: any LicenseVerifying
        if let configured = try? CryptoKitLicenseVerifier.trusting(DemoVendorKeys.trustedPublicKeys) {
            verifier = configured
        } else {
            verifier = RejectingVerifier()
            notes.append("The embedded public key could not be read. Every signature will now fail.")
        }

        // 3. The rule chain.
        var validator: LicenseValidator
        switch setup.validatorPreset {
        case .offline:
            validator = .offlineDefault(
                signaturePolicy: setup.signaturePolicy.policy,
                expiryWarningThreshold: .licenseDays(setup.expiryWarningDays)
            )
        case .connected:
            validator = .connectedDefault(
                signaturePolicy: setup.signaturePolicy.policy,
                expiryWarningThreshold: .licenseDays(setup.expiryWarningDays)
            )
        }

        var disabled: Set<RuleIdentifier> = []
        if !setup.enforcesMachineBinding { disabled.insert(.machineBinding) }
        if !setup.enforcesSeatLimit { disabled.insert(.seatLimit) }
        if !setup.detectsClockTampering { disabled.insert(.clockTamper) }
        validator = validator.removing(disabled)

        if setup.enforcesSiteDomainRule {
            // The extension point, in full. A rule is a pure function of its
            // context — no `Date()`, no `UserDefaults`, no network, because the
            // chain runs on every validation including feature gates.
            validator = validator.adding([
                ClosureRule(id: "demo.siteDomain") { context in
                    guard let email = context.license.subject.email else {
                        // `.notApplicable`, not `.satisfied`: a report must never
                        // imply a check ran when there was nothing to check.
                        return .notApplicable
                    }
                    return email.hasSuffix("@acme.example")
                        ? .satisfied
                        : .failed(.custom(
                            rule: "demo.siteDomain",
                            message: "\(email) is not a licensed domain"
                        ))
                }
            ])
        }

        // 4. Who this device claims to be. The fingerprint is salted and hashed
        //    before it leaves the machine, so seat accounting never receives a
        //    hardware identifier.
        let machineIdentity: any MachineIdentityProviding = setup.identifiesAsThisMac
            ? PlatformMachineIdentity(salt: DemoProduct.fingerprintSalt)
            : StaticMachineIdentity("someone-elses-mac", deviceName: "A Mac that isn't yours")

        // 5. The provider. `RemoteLicenseProvider` supplies retry, backoff, and
        //    status mapping; `DemoStoreAdapter` supplies only the translation;
        //    `DemoHTTPTransport` swaps the network for an in-process service.
        let provider = RemoteLicenseProvider(
            adapter: DemoStoreAdapter(),
            transport: DemoHTTPTransport(backend: backend),
            retryPolicy: RetryPolicy(maximumRetries: setup.maximumRetries),
            clock: clock,
            log: recorder.licenseLog
        )

        let configuration = LicenseKitConfiguration(
            product: DemoProduct.id,
            verifier: verifier,
            applicationVersion: SemanticVersion(string: setup.applicationVersion),
            store: store,
            providers: [provider],
            validator: validator,
            machineIdentity: machineIdentity,
            clock: clock,
            timeAnchor: setup.persistsTimeAnchor ? UserDefaultsTimeAnchor() : InMemoryTimeAnchor(),
            refreshPolicy: RefreshPolicy(
                refreshesOnStart: setup.refreshesOnStart,
                minimumInterval: setup.minimumRefreshInterval,
                eagerRefreshWindow: .licenseDays(setup.eagerRefreshDays)
            ),
            log: recorder.licenseLog
        )

        // An app that ships unsealed licenses passes no unsealer and links no
        // symmetric crypto at all. Turning this off in Setup shows what a sealed
        // file looks like when the key is missing.
        var fileReader = LicenseFileReader()
        if setup.configuresSealingKey {
            if let sealingKey = try? DemoVendorKeys.sealingKey() {
                fileReader = .sealed(key: sealingKey)
            } else {
                notes.append("The embedded sealing key could not be read; sealed files will not open.")
            }
        }

        if SemanticVersion(string: setup.applicationVersion) == nil {
            notes.append(
                "'\(setup.applicationVersion)' is not a semantic version, so "
                + "VersionBoundRule has nothing to compare and reports itself "
                + "not applicable."
            )
        }

        return DemoRuntime(
            setup: setup,
            manager: LicenseManager(configuration: configuration),
            providers: [provider],
            fileReader: fileReader,
            factory: DemoLicenseFactory(clock: clock),
            resolvedApplicationVersion: SemanticVersion(string: setup.applicationVersion),
            storeDescription: storeDescription,
            activeRules: validator.rules.map(\.id),
            notes: notes
        )
    }

    /// Whether the provider backing the installed record can release a seat.
    ///
    /// A licensing UI should ask this before showing a "deactivate this Mac"
    /// button, rather than offering an operation that will certainly fail.
    func supportsDeactivation(for record: LicenseRecord?) -> Bool {
        guard let record else { return false }
        return providers
            .first { $0.providerID == record.origin.provider }?
            .capabilities.contains(.deactivation) ?? false
    }
}
