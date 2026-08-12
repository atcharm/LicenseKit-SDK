import Foundation
import LicenseKit
import LicenseKitVendor

/// A tiny sink so the demo can show what the "server" did.
public struct DemoEventSink: Sendable {
    let emit: @Sendable (String) -> Void

    public init(_ emit: @escaping @Sendable (String) -> Void) {
        self.emit = emit
    }

    public static let discard = DemoEventSink { _ in }
}

/// A licensing service, in memory.
///
/// This stands in for Gumroad, Polar, or your own fulfilment API. It speaks the
/// same shape those services do — a key database, seat accounting, a lifecycle
/// status, and a habit of failing in interesting ways — so the app talks to it
/// through the real `RemoteLicenseProvider` with a real adapter, and every retry,
/// backoff, and error mapping in the SDK actually executes.
///
/// Nothing in here is code you would ship. It exists so the demo can produce a
/// seat-limit rejection or a 503 on demand instead of asking you to arrange one.
public actor DemoStoreBackend {
    /// How the service is behaving right now.
    ///
    /// The distinction the SDK cares about is transient versus definitive: a
    /// timeout must not revoke a paying customer's license, and a refund must
    /// not be papered over by a retry.
    public enum Condition: String, CaseIterable, Sendable, Identifiable {
        case healthy
        case slow
        case flaky
        case unreachable
        case timeout
        case rateLimited
        case serverError
        case unauthorized
        case malformed

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .healthy: return "Healthy"
            case .slow: return "Slow (1.5s)"
            case .flaky: return "Fails once, then succeeds"
            case .unreachable: return "No network"
            case .timeout: return "Times out"
            case .rateLimited: return "429 Too Many Requests"
            case .serverError: return "503 Service Unavailable"
            case .unauthorized: return "401 Unauthorized"
            case .malformed: return "200 with a broken body"
            }
        }

        public var effect: String {
            switch self {
            case .healthy:
                return "Requests succeed."
            case .slow:
                return "Every request takes 1.5 seconds — watch the loading state."
            case .flaky:
                return "The first attempt of each operation returns 503. The "
                    + "provider's retry policy absorbs it and the second attempt "
                    + "succeeds, so the app never sees an error."
            case .unreachable:
                return "Transient. Refresh keeps the cached license and lets the "
                    + "grace rules decide; it does not revoke."
            case .timeout:
                return "Transient, same treatment as no network."
            case .rateLimited:
                return "Transient, with a Retry-After the provider honours over "
                    + "its own backoff. Retries are exhausted, then it throws."
            case .serverError:
                return "Transient. Retried, then reported — a server fault is "
                    + "never read as a revocation."
            case .unauthorized:
                return "Definitive. Your app's credentials were refused; retrying "
                    + "would not help, so it does not."
            case .malformed:
                return "The service answered, but not in a shape the adapter "
                    + "understands. Definitive, and worth logging loudly."
            }
        }

        /// Whether the SDK treats this as a temporary problem.
        public var isTransient: Bool {
            switch self {
            case .healthy, .slow, .flaky: return true
            case .unreachable, .timeout, .rateLimited, .serverError: return true
            case .unauthorized, .malformed: return false
            }
        }
    }

    /// One purchase in the service's database.
    public struct Account: Sendable, Identifiable, Hashable {
        public var key: String
        public var title: String
        public var detail: String
        public var kind: LicenseKind
        public var entitlements: EntitlementSet
        public var seatLimit: Int?
        public var status: ProviderStateSnapshot.Status
        /// The term written into the signed license at issuance.
        public var termExpiresAt: Date?
        /// What the service currently asserts. A renewal moves this forward
        /// without reissuing anything — which is exactly why
        /// `LicenseRecord.effectiveExpiry` prefers it over the signed policy.
        public var providerExpiresAt: Date?
        /// Fingerprint → device name.
        public var activations: [String: String]

        public var id: String { key }

        public var seatsUsed: Int { activations.count }
    }

    // MARK: - State

    private let clock: any LicenseClock
    private let factory: DemoLicenseFactory
    private let log: DemoEventSink

    private var accounts: [String: Account] = [:]
    private var condition: Condition = .healthy
    private var signsLicenses = true
    /// Per-operation counter used by `.flaky`.
    private var flakyStrikes: [String: Int] = [:]

    public static let baseURL = URL(string: "https://demo.licensing.example")!

    public init(clock: any LicenseClock, log: DemoEventSink = .discard) {
        self.clock = clock
        self.factory = DemoLicenseFactory(clock: clock)
        self.log = log
        self.accounts = Self.seededAccounts(at: clock.now)
    }

    /// The service's initial database.
    ///
    /// `static`, and taking `now` rather than reading the clock, so that an actor
    /// initialiser can call it. An `init` runs before the actor's isolation is
    /// established, so it cannot call an isolated method — which is exactly the
    /// kind of thing Swift 6's concurrency checking is for.
    private static func seededAccounts(at now: Date) -> [String: Account] {
        let seeded: [Account] = [
            Account(
                key: "APERT-STUDIO-PERPETUAL",
                title: "Studio, perpetual",
                detail: "Three seats, every entitlement, never expires.",
                kind: .perpetual,
                entitlements: DemoEntitlement.studioSet,
                seatLimit: 3,
                status: .active,
                termExpiresAt: nil,
                providerExpiresAt: nil,
                activations: [:]
            ),
            Account(
                key: "APERT-STUDIO-MONTHLY",
                title: "Studio, monthly",
                detail: "Renews in 20 days. Two seats. Try renewing and revoking it.",
                kind: .subscription,
                entitlements: DemoEntitlement.studioSet,
                seatLimit: 2,
                status: .active,
                termExpiresAt: now.addingTimeInterval(.licenseDays(20)),
                providerExpiresAt: now.addingTimeInterval(.licenseDays(20)),
                activations: [:]
            ),
            Account(
                key: "APERT-STANDARD-SOLO",
                title: "Standard, single seat",
                detail: "One seat only — the shortest path to a seat-limit rejection.",
                kind: .perpetual,
                entitlements: DemoEntitlement.standardSet,
                seatLimit: 1,
                status: .active,
                termExpiresAt: nil,
                providerExpiresAt: nil,
                activations: [:]
            ),
            Account(
                key: "APERT-TRIAL-14DAY",
                title: "Trial, 3 days left",
                detail: "Inside the warning threshold, so a valid license still "
                    + "carries something to tell the user.",
                kind: .trial,
                entitlements: DemoEntitlement.standardSet,
                seatLimit: 1,
                status: .active,
                termExpiresAt: now.addingTimeInterval(.licenseDays(3)),
                providerExpiresAt: now.addingTimeInterval(.licenseDays(3)),
                activations: [:]
            ),
            Account(
                key: "APERT-REFUNDED-9999",
                title: "Refunded",
                detail: "The purchase was charged back. Activation is refused; an "
                    + "already-installed copy is revoked on the next refresh.",
                kind: .perpetual,
                entitlements: DemoEntitlement.studioSet,
                seatLimit: 3,
                status: .revoked,
                termExpiresAt: nil,
                providerExpiresAt: nil,
                activations: [:]
            ),
        ]
        return Dictionary(seeded.map { (LicenseKey($0.key).normalized, $0) }) { _, last in last }
    }

    // MARK: - Operator controls
    //
    // The buttons behind the "Service" panel. In production these are things
    // that happen in a dashboard, a webhook, or a payment processor's retry.

    public func currentCondition() -> Condition { condition }

    public func setCondition(_ newValue: Condition) {
        condition = newValue
        flakyStrikes.removeAll()
        log.emit("service condition → \(newValue.rawValue)")
    }

    public func issuesSignedLicenses() -> Bool { signsLicenses }

    /// When off, the service returns licenses with no signature — the shape of a
    /// provider that relies on TLS for authenticity. Whether that is acceptable
    /// is the host's call, expressed through `SignatureRule.Policy`.
    public func setIssuesSignedLicenses(_ newValue: Bool) {
        signsLicenses = newValue
        log.emit("service now returns \(newValue ? "signed" : "unsigned") licenses")
    }

    public func allAccounts() -> [Account] {
        accounts.values.sorted { $0.key < $1.key }
    }

    public func account(matching key: String) -> Account? {
        accounts[LicenseKey(key).normalized]
    }

    public func revoke(_ key: String) {
        mutate(key) { $0.status = .revoked }
        log.emit("\(key) revoked (chargeback)")
    }

    public func reinstate(_ key: String) {
        mutate(key) { $0.status = .active }
        log.emit("\(key) reinstated")
    }

    /// Moves the asserted expiry forward without reissuing the license.
    public func renew(_ key: String, byDays days: Double = 30) {
        let now = clock.now
        mutate(key) { account in
            let base = max(account.providerExpiresAt ?? now, now)
            account.providerExpiresAt = base.addingTimeInterval(.licenseDays(days))
            account.status = .active
        }
        log.emit("\(key) renewed by \(Int(days)) day(s) — provider state only, no reissue")
    }

    /// Marks a subscription as lapsed, the way a failed payment would.
    public func lapse(_ key: String) {
        mutate(key) { $0.status = .lapsed }
        log.emit("\(key) lapsed (payment failed)")
    }

    /// Occupies a seat from a machine that is not this one.
    public func occupySeat(on key: String, deviceName: String = "Dana's MacBook Air") {
        mutate(key) { account in
            let fingerprint = "other-device-\(account.activations.count + 1)"
            account.activations[fingerprint] = deviceName
        }
        if let account = account(matching: key) {
            log.emit("\(key) seat taken by \(deviceName) — \(account.seatsUsed)"
                + "/\(account.seatLimit.map(String.init) ?? "∞") in use")
        }
    }

    public func releaseAllSeats(on key: String) {
        mutate(key) { $0.activations.removeAll() }
        log.emit("\(key) seats cleared")
    }

    public func reset() {
        accounts = Self.seededAccounts(at: clock.now)
        condition = .healthy
        signsLicenses = true
        flakyStrikes.removeAll()
        log.emit("service reset")
    }

    private func mutate(_ key: String, _ body: (inout Account) -> Void) {
        let normalized = LicenseKey(key).normalized
        guard var account = accounts[normalized] else { return }
        body(&account)
        accounts[normalized] = account
    }

    // MARK: - The API itself

    /// Routes a request the way an HTTP server would.
    ///
    /// Throwing `LicenseProviderError` here models a failure *below* HTTP — a
    /// connection that never opened. Everything the server actually answered
    /// comes back as an `HTTPResponse`, including its errors, because that is
    /// what a transport sees.
    func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        let operation = request.url.lastPathComponent
        log.emit("→ \(request.method.rawValue) /\(operation)")

        switch condition {
        case .healthy:
            break
        case .slow:
            try await sleep(seconds: 1.5)
        case .flaky:
            let strikes = flakyStrikes[operation] ?? 0
            if strikes == 0 {
                flakyStrikes[operation] = 1
                log.emit("← 503 (first attempt — the provider will retry)")
                return json(status: 503, ["error": "overloaded"])
            }
        case .unreachable:
            log.emit("✗ connection failed")
            throw LicenseProviderError.unreachable(reason: "the demo network is switched off")
        case .timeout:
            try await sleep(seconds: 0.4)
            log.emit("✗ timed out")
            throw LicenseProviderError.timedOut
        case .rateLimited:
            log.emit("← 429 Retry-After: 1")
            return HTTPResponse(
                status: 429,
                headers: ["Retry-After": "1"],
                body: Data(#"{"error":"rate_limited"}"#.utf8)
            )
        case .serverError:
            log.emit("← 503")
            return json(status: 503, ["error": "overloaded"])
        case .unauthorized:
            log.emit("← 401")
            return json(status: 401, ["error": "bad_credentials"])
        case .malformed:
            log.emit("← 200 with a body the adapter cannot read")
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data("<html>maintenance</html>".utf8)
            )
        }

        let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
        let key = body["key"] as? String ?? ""
        let fingerprint = body["fingerprint"] as? String
        let device = body["device"] as? String

        switch operation {
        case "activate":
            return try activate(key: key, fingerprint: fingerprint, device: device)
        case "validate":
            return try validate(key: key, fingerprint: fingerprint)
        case "deactivate":
            return deactivate(key: key, fingerprint: fingerprint)
        default:
            return json(status: 404, ["error": "no_such_endpoint"])
        }
    }

    private func activate(key: String, fingerprint: String?, device: String?) throws -> HTTPResponse {
        guard let account = account(matching: key) else {
            log.emit("← 404 unknown key \(LicenseKey(key).redacted)")
            return json(status: 404, ["error": "unknown_key"])
        }

        // A refunded purchase answers 200 with `ok: false`. Several real
        // licensing APIs do exactly this, which is why `RemoteProviderAdapter`
        // lets an adapter read meaning out of a body a status code cannot see.
        guard account.status != .revoked else {
            log.emit("← 200 ok=false (refunded)")
            return json(status: 200, [
                "ok": false,
                "error": "revoked",
                "message": "This purchase was refunded.",
            ])
        }

        var updated = account
        if let fingerprint {
            let alreadyHere = updated.activations[fingerprint] != nil
            if !alreadyHere, let limit = updated.seatLimit, updated.activations.count >= limit {
                log.emit("← 409 seat limit (\(updated.activations.count)/\(limit))")
                return json(status: 409, [
                    "error": "seat_limit",
                    "message": "All \(limit) seat(s) are in use.",
                ])
            }
            updated.activations[fingerprint] = device ?? "This Mac"
            accounts[LicenseKey(key).normalized] = updated
        }

        log.emit("← 200 activated (\(updated.seatsUsed)/\(updated.seatLimit.map(String.init) ?? "∞") seats)")
        return try success(for: updated, activationID: fingerprint)
    }

    private func validate(key: String, fingerprint: String?) throws -> HTTPResponse {
        guard let account = account(matching: key) else {
            log.emit("← 404 unknown key")
            return json(status: 404, ["error": "unknown_key"])
        }
        log.emit("← 200 status=\(account.status.rawValue)")
        return try success(for: account, activationID: fingerprint)
    }

    private func deactivate(key: String, fingerprint: String?) -> HTTPResponse {
        guard var account = account(matching: key) else {
            return json(status: 404, ["error": "unknown_key"])
        }
        if let fingerprint {
            account.activations[fingerprint] = nil
            accounts[LicenseKey(key).normalized] = account
        }
        log.emit("← 200 seat released (\(account.seatsUsed) still in use)")
        return json(status: 200, ["ok": true])
    }

    // MARK: - Response building

    private func success(for account: Account, activationID: String?) throws -> HTTPResponse {
        let now = clock.now
        let license = makeLicense(for: account, at: now)

        var payload: [String: Any] = [
            "ok": true,
            "signed": signsLicenses,
            "status": account.status.rawValue,
            "seats": [
                "used": account.seatsUsed,
                // `JSONSerialization` refuses a bare `Optional`, so an absent
                // ceiling has to be spelled as an explicit null.
                "total": account.seatLimit.map { $0 as Any } ?? NSNull(),
            ] as [String: Any],
        ]

        if let expiry = account.providerExpiresAt {
            payload["expires_at"] = ISO8601Timestamp.string(from: expiry)
        }
        if let activationID {
            payload["activation_id"] = activationID
        }

        let codec = JSONLicenseCodec()
        if signsLicenses {
            let issuer = LicenseIssuer(signingKey: try DemoVendorKeys.signingKey(), clock: clock)
            payload["license"] = try codec.encode(try issuer.sign(license)).base64EncodedString()
        } else {
            payload["license"] = try codec.encode(license).base64EncodedString()
        }

        return json(status: 200, payload)
    }

    /// Mints the claim set the service asserts for an account.
    ///
    /// The signed term is deliberately *not* the renewable expiry: a renewal
    /// moves `providerExpiresAt` and the signature stays untouched. That split
    /// is why a subscription can be extended without the vendor reissuing
    /// anything, and why the app reads `record.effectiveExpiry` rather than the
    /// policy's own window.
    private func makeLicense(for account: Account, at now: Date) -> License {
        var policy = LicensePolicy(
            kind: account.kind,
            validity: ValidityWindow(expiresAt: account.termExpiresAt)
        )
        if let seatLimit = account.seatLimit {
            policy.seats = .seats(seatLimit)
        }
        if account.kind != .perpetual {
            // Bound how long the app runs on a cached "valid" answer. Without
            // this, revocation means nothing to a device that never checks in.
            policy.offlineGraceInterval = .licenseDays(30)
            policy.expiryGraceInterval = .licenseDays(3)
        }

        var metadata = LicenseMetadata()
        metadata["demo.account"] = .string(account.key)
        metadata["demo.plan"] = .string(account.title)

        return License(
            id: LicenseID(rawValue: "demo-remote-\(LicenseKey(account.key).normalized)"),
            key: LicenseKey(account.key),
            product: DemoProduct.reference,
            subject: LicenseSubject(
                customerID: "cus_4A19F0",
                name: "Dana Okonkwo",
                email: "dana@northlight.example",
                organization: "Northlight Studio"
            ),
            policy: policy,
            entitlements: account.entitlements,
            issuance: IssuanceInfo(issuer: DemoProduct.issuer, issuedAt: now),
            metadata: metadata
        )
    }

    private func json(status: Int, _ payload: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    private func sleep(seconds: Double) async throws {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            throw LicenseProviderError.cancelled
        }
    }
}

/// Routes SDK requests to the in-memory service instead of the network.
///
/// `HTTPTransport` has one method, which is the whole point: substituting your
/// own networking stack — certificate pinning, a shared request queue, or a
/// recorded fixture like this one — costs three lines and needs no cooperation
/// from the SDK.
public struct DemoHTTPTransport: HTTPTransport {
    private let backend: DemoStoreBackend

    public init(backend: DemoStoreBackend) {
        self.backend = backend
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await backend.handle(request)
    }
}
