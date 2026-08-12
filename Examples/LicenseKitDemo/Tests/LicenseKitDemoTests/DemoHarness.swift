import DemoBackstage
import Foundation
import LicenseKit

/// A clock the tests can move.
///
/// The reason the whole lifecycle is testable without sleeping: every expiry
/// decision in LicenseKit reads `LicenseClock`, never `Date()`.
final class MovableClock: LicenseClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOffset: TimeInterval = 0

    var now: Date { Date().addingTimeInterval(lock.withLock { storedOffset }) }

    func travel(days: Double) {
        lock.withLock { storedOffset += .licenseDays(days) }
    }
}

/// Assembles a licensing stack for one test.
///
/// Deliberately mirrors what the app's `DemoRuntime.make` does, with every seam
/// exposed as a parameter. This is the shape of test setup worth copying: no
/// network, no sleeping, no shared global state between tests.
struct DemoHarness {
    let clock: MovableClock
    let backend: DemoStoreBackend
    let store: any LicenseStore
    let manager: LicenseManager
    let factory: DemoLicenseFactory
    let reader: LicenseFileReader

    init(
        signaturePolicy: SignatureRule.Policy = .requiredWhenPresent,
        connected: Bool = true,
        fingerprint: MachineFingerprint = "test-machine",
        applicationVersion: SemanticVersion? = "2.0.0",
        maximumRetries: Int = 2,
        refreshesOnStart: Bool = false,
        configuresSealingKey: Bool = true,
        store: (any LicenseStore)? = nil,
        clock: MovableClock = MovableClock(),
        backend: DemoStoreBackend? = nil,
        timeAnchor: (any MonotonicTimeAnchor)? = nil
    ) throws {
        self.clock = clock
        let backend = backend ?? DemoStoreBackend(clock: clock)
        self.backend = backend

        let store = store ?? InMemoryLicenseStore()
        self.store = store

        self.factory = DemoLicenseFactory(clock: clock)
        self.reader = configuresSealingKey
            ? .sealed(key: try DemoVendorKeys.sealingKey())
            : LicenseFileReader()

        let validator = connected
            ? LicenseValidator.connectedDefault(signaturePolicy: signaturePolicy)
            : LicenseValidator.offlineDefault(signaturePolicy: signaturePolicy)

        self.manager = LicenseManager(configuration: LicenseKitConfiguration(
            product: DemoProduct.id,
            verifier: try CryptoKitLicenseVerifier.trusting(DemoVendorKeys.trustedPublicKeys),
            applicationVersion: applicationVersion,
            store: store,
            providers: [
                RemoteLicenseProvider(
                    adapter: DemoStoreAdapter(),
                    transport: DemoHTTPTransport(backend: backend),
                    retryPolicy: RetryPolicy(maximumRetries: maximumRetries),
                    clock: clock
                )
            ],
            validator: validator,
            machineIdentity: StaticMachineIdentity(fingerprint, deviceName: "Test Mac"),
            clock: clock,
            // In-memory rather than `UserDefaultsTimeAnchor`, so tests running in
            // parallel cannot see each other's high-water marks.
            timeAnchor: timeAnchor ?? InMemoryTimeAnchor(),
            refreshPolicy: RefreshPolicy(
                refreshesOnStart: refreshesOnStart,
                minimumInterval: 0,
                eagerRefreshWindow: nil
            )
        ))
    }

    /// A fresh manager over the *same* store, clock, and backend — a relaunch.
    func relaunched(
        fingerprint: MachineFingerprint = "test-machine",
        applicationVersion: SemanticVersion? = "2.0.0",
        signaturePolicy: SignatureRule.Policy = .requiredWhenPresent
    ) throws -> DemoHarness {
        try DemoHarness(
            signaturePolicy: signaturePolicy,
            fingerprint: fingerprint,
            applicationVersion: applicationVersion,
            store: store,
            clock: clock,
            backend: backend
        )
    }
}

// MARK: - Assertion helpers

extension ValidationReport {
    func hasFailure(_ predicate: (ValidationFailureReason) -> Bool) -> Bool {
        failures.contains(where: predicate)
    }

    func hasWarning(_ predicate: (ValidationWarning) -> Bool) -> Bool {
        warnings.contains(where: predicate)
    }
}

extension LicenseState {
    var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }
}

enum DemoKeys {
    static let perpetual = "APERT-STUDIO-PERPETUAL"
    static let monthly = "APERT-STUDIO-MONTHLY"
    static let solo = "APERT-STANDARD-SOLO"
    static let trial = "APERT-TRIAL-14DAY"
    static let refunded = "APERT-REFUNDED-9999"
}
