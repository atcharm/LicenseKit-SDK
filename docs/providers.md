# Providers

A **provider** is an authority you ask permission from: Gumroad, Polar, Paddle,
your own backend. This page covers using the included ones and writing your own.

The test of the architecture is that adding a provider touches **no existing
file**. If you ever find yourself editing `LicenseKitCore` to support a store,
something has gone wrong — open an issue.

## Sources vs providers

Two protocols that look similar and are not.

| | `LicenseSource` | `LicenseProvider` |
|---|---|---|
| Question | "What licenses exist?" | "May this device use this key?" |
| Examples | CSV table, bundled manifest | Gumroad, Polar, your API |
| Seats | No | Usually |
| Network | No | Usually |
| Side effects | None | Claims and releases seats |

Merging them would force every CSV file to implement — and refuse — four network
operations, and would make `capabilities` meaningless. `OfflineLicenseProvider`
bridges a source into the provider protocol when you want to activate against a
file through the same call you use for an API.

## Using a provider

```swift
let gumroad = RemoteLicenseProvider(
    adapter: GumroadAdapter(
        productID: "abc123",                                   // Gumroad's product ID
        product: ProductReference(id: "com.example.app"),      // yours
        grantedEntitlements: [Entitlement(id: "export.pdf")],
        seatLimit: 3
    ),
    transport: URLSessionHTTPTransport.ephemeral(),
    retryPolicy: .default
)

let configuration = LicenseKitConfiguration(
    product: "com.example.app",
    verifier: verifier,
    store: store,
    providers: [gumroad],
    validator: .connectedDefault()
)
```

Note the two product identifiers. `productID` is the store's opaque string;
`product` is yours. Keeping them separate is why your domain never inherits a
vendor's vocabulary — swap stores and your entitlement checks do not move.

```swift
try await licensing.activate(key: "GUM-0001")   // redeem, claim a seat
try await licensing.refresh()                   // re-check status
try await licensing.deactivate()                // release the seat, forget locally
```

`activate` picks the first configured provider that supports activation; pass
`providerID:` to choose.

## Capabilities

Providers differ enormously. Some track seats; some only answer "is this key
real?"; some are read-only tables. Declaring capabilities lets the runtime skip
operations that would certainly fail, and lets your UI hide controls a provider
cannot honour — without your code branching on which provider it is.

```swift
ProviderCapabilities: .activation, .deactivation, .refresh,
                      .remoteValidation, .seatAccounting, .signedLicenses

.verificationOnly   // [.remoteValidation, .refresh]
.full               // everything but .signedLicenses
```

```swift
if provider.capabilities.contains(.deactivation) {
    showReleaseThisDeviceButton()
}
```

That check is the entire reason capabilities exist. Gumroad has no seat-release
endpoint, so `GumroadAdapter` does not advertise `.deactivation`, and a
"deactivate this device" button that would always fail simply never appears.

## Included adapters

### Gumroad

```swift
GumroadAdapter(
    productID: "abc123",
    product: ProductReference(id: "com.example.app"),
    endpoint: GumroadAdapter.defaultEndpoint,
    incrementUsesCount: false,
    grantedEntitlements: [Entitlement(id: "export.pdf")],
    seatLimit: 3
)
```

Capabilities: `.activation`, `.remoteValidation`, `.refresh`, `.seatAccounting`.
No deactivation — the API has no seat-release endpoint.

**`incrementUsesCount` defaults to `false`, and should stay that way for
validation.** Gumroad's use counter is its seat count. Incrementing on every
launch inflates it until a legitimate customer with a 3-seat license appears to
have used 400 seats. Increment only at genuine activation.

Mapping:

| Gumroad | Domain |
|---|---|
| `purchase.refunded` / `disputed` / `chargebacked` | `status = .revoked` |
| `subscription_cancelled_at` / `_ended_at` / `_failed_at` (earliest) | `expiresAt` |
| `uses` | `activationCount` |
| `purchase.sale_id` | `LicenseID` |
| HTTP 404 or `success: false` | `.licenseNotFound` / `.rejected` |

A refund maps to `.revoked` rather than `.expired` because the distinction is
actionable: revoked means "this is gone", expired means "renew me".

### Polar

```swift
PolarAdapter(
    organizationID: "org-1",
    product: ProductReference(id: "com.example.app"),
    activationLabel: "My App",
    grantedEntitlements: [Entitlement(id: "export.pdf")]
)
```

Capabilities: `.full`. Polar models activations as first-class objects with their
own IDs, so genuine seat release works.

The captured `activation.id` is what makes `deactivate()` possible — without it
there is no way to name the seat to release. `MachineBindingRule` then ties the
record to this device.

Mapping:

| Polar | Domain |
|---|---|
| `status: granted` | `.active` |
| `status: revoked` / `disabled` | `.revoked` |
| unrecognised status | `.unknown` — never assumed good |
| `expires_at` in the past | `.lapsed` |
| `limit_activations` | `seats.maxActivations` |
| HTTP 422 mentioning activation | `.seatLimitReached` |

> Endpoints and field names for both adapters reflect each service's public API at
> the time of writing, and are decoded defensively so an added or renamed optional
> field degrades rather than breaks. Verify them against current documentation
> before shipping, and treat the endpoint as configuration.

## Writing an adapter

An adapter is **pure translation**: build a request, decode a response. It performs
no I/O, no retries, and makes no policy decisions.

That constraint is the point. `RemoteLicenseProvider` owns dispatch, capability
checks, retry with backoff, cancellation, and status-code mapping — once, for every
adapter. So your adapter has no asynchronous code and no networking dependency, can
be tested exhaustively against recorded response bodies, and a retry bug gets fixed
in one place instead of once per integration.

```swift
import LicenseKit

struct AcmeAdapter: RemoteProviderAdapter {
    let providerID: ProviderID = "acme"
    let product: ProductReference
    let apiKey: String

    var capabilities: ProviderCapabilities {
        [.activation, .deactivation, .refresh, .remoteValidation, .seatAccounting]
    }

    // MARK: Requests

    func activationRequest(for request: ActivationRequest) throws -> HTTPRequest {
        HTTPRequest.formPost(
            url: URL(string: "https://api.acme.test/v1/licenses/redeem")!,
            fields: [
                "key": request.key.rawValue,
                "device": request.fingerprint?.rawValue ?? "",
                "label": request.deviceName ?? "",
            ],
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
    }

    func validationRequest(for record: LicenseRecord) throws -> HTTPRequest {
        HTTPRequest.formPost(
            url: URL(string: "https://api.acme.test/v1/licenses/check")!,
            fields: ["key": record.license.key.rawValue],
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
    }

    func deactivationRequest(for record: LicenseRecord) throws -> HTTPRequest {
        guard let activationID = record.activation?.id.rawValue else {
            throw LicenseProviderError.rejected(reason: "no activation to release")
        }
        return HTTPRequest.formPost(
            url: URL(string: "https://api.acme.test/v1/licenses/release")!,
            fields: ["activation": activationID],
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
    }

    // MARK: Responses

    func decodeActivation(
        _ response: HTTPResponse,
        for request: ActivationRequest,
        at now: Date
    ) throws -> LicenseRecord {
        let json = try JSONValue(parsing: response.body)

        var activation: ActivationInfo?
        if let id = json["activation_id"].string, let fingerprint = request.fingerprint {
            activation = ActivationInfo(
                id: ActivationID(rawValue: id),
                fingerprint: fingerprint,
                activatedAt: now,
                deviceName: request.deviceName
            )
        }

        return LicenseRecord(
            license: makeLicense(from: json, key: request.key, at: now),
            origin: LicenseOrigin(provider: providerID, medium: .remote, retrievedAt: now),
            activation: activation,
            providerState: makeState(from: json, at: now),
            lastValidatedAt: now
        )
    }

    func decodeValidation(
        _ response: HTTPResponse,
        for record: LicenseRecord,
        at now: Date
    ) throws -> RemoteValidationResult {
        let json = try JSONValue(parsing: response.body)
        return RemoteValidationResult(state: makeState(from: json, at: now))
    }

    func decodeDeactivation(_ response: HTTPResponse, for record: LicenseRecord) throws {
        // 2xx with no useful body — nothing to decode.
    }

    // MARK: Mapping

    private func makeLicense(from json: JSONValue, key: LicenseKey, at now: Date) -> License {
        var policy = LicensePolicy(kind: .subscription)
        policy.validity = ValidityWindow(expiresAt: json["expires_at"].date)
        if let seats = json["seat_limit"].int { policy.seats = .seats(seats) }
        policy.offlineGraceInterval = .licenseDays(30)

        return License(
            // Prefer the provider's own stable ID so re-activating updates one
            // record instead of accumulating duplicates.
            id: LicenseID(rawValue: json["id"].string ?? "acme:\(key.normalized)"),
            key: key,
            product: product,
            subject: LicenseSubject(
                customerID: json.at("customer", "id").string,
                email: json.at("customer", "email").string
            ),
            policy: policy,
            entitlements: EntitlementSet(
                (json["features"].array ?? [])
                    .compactMap(\.string)
                    .map { Entitlement(id: EntitlementID(rawValue: $0)) }
            ),
            issuance: IssuanceInfo(issuer: "acme", issuedAt: json["created_at"].date ?? now)
        )
    }

    private func makeState(from json: JSONValue, at now: Date) -> ProviderStateSnapshot {
        let status: ProviderStateSnapshot.Status
        switch json["status"].string?.lowercased() {
        case "active":              status = .active
        case "revoked", "refunded": status = .revoked
        case "past_due":            status = .lapsed
        // An unrecognised status is never assumed good.
        default:                    status = .unknown
        }

        return ProviderStateSnapshot(
            status: status,
            expiresAt: json["expires_at"].date,
            activationCount: json["seats_used"].int,
            observedAt: now
        )
    }
}
```

Only implement what your `capabilities` advertise. Every other method defaults to
reporting itself unsupported, so adding an operation to the protocol later cannot
break your adapter.

### Mapping errors

The default `mapFailure` handles the usual status codes. Override it when your
service signals meaning through the body — several licensing APIs return HTTP 200
with `{"success": false}`, which no status-code mapping can see:

```swift
func mapFailure(
    _ response: HTTPResponse,
    for operation: ProviderOperation
) -> LicenseProviderError {
    if let json = try? JSONValue(parsing: response.body),
       json["error"].string == "seat_limit" {
        return .seatLimitReached
    }
    if response.status == 404 { return .licenseNotFound }
    if (500...599).contains(response.status) {
        return .server(status: response.status, message: nil)
    }
    return .rejected(reason: response.bodyText)
}
```

**Get the transient/definitive split right — it is the highest-stakes decision in
an adapter.**

```swift
error.isTransient   // true: unreachable, timedOut, rateLimited, server(5xx)
                    // false: unauthorized, licenseNotFound, rejected,
                    //        seatLimitReached, malformedResponse, cancelled
```

Transient failures preserve the cached record and let offline grace decide.
Definitive ones revoke it locally. Map a flaky network to `.rejected` and you
deactivate paying customers on hotel Wi-Fi. Map a refund to `.unreachable` and a
refunded license runs forever.

### Decode defensively

Adapters deliberately avoid `Codable` structs for provider responses.

Licensing APIs change shape without warning, return `null` where they documented a
string, and encode booleans as `"true"`. A `Codable` struct turns any of those into
a total decode failure — which locks a paying customer out over a field you never
needed.

```swift
let json = try JSONValue(parsing: response.body)

json["status"].string           // nil rather than throwing
json["seats"].int               // parses "3" and 3 alike
json["active"].bool             // parses true, 1, and "yes"
json["expires_at"].date         // ISO-8601 or Unix timestamp
json.at("customer", "email")    // missing paths return .null, never crash
```

`JSONValue` also distinguishes `true` from `1`, which `NSNumber` erases — and a
field like `refunded` deciding whether software runs is not a place to get that
wrong.

## Retry policy

```swift
RetryPolicy(
    maximumRetries: 2,
    initialDelay: 0.5,      // doubles each attempt
    maximumDelay: 8,
    jitterFraction: 0.25    // avoids a thundering herd on reconnect
)

.default   // the above
.none      // no retries
```

Only transient failures are retried; a settled answer is not worth re-asking. A
server-supplied `Retry-After` overrides the computed backoff.

The jitter matters more than it looks. Without it, every client knocked offline by
one outage reconnects in lockstep and retries in lockstep, turning your recovery
into a second outage.

## Testing an adapter

This is where the design pays off — no network, no `URLProtocol` subclass, no
flakiness.

```swift
@Test func refundIsReportedAsRevocation() async throws {
    let provider = RemoteLicenseProvider(
        adapter: AcmeAdapter(product: "com.example.app", apiKey: "test"),
        transport: StubHTTPTransport(always: .json(#"{"status": "refunded"}"#)),
        retryPolicy: .none,
        clock: FixedLicenseClock(fixedInstant)
    )

    let result = try await provider.validate(record)
    #expect(result.state.status == .revoked)
}
```

Assert on the requests you produce, too:

```swift
let recorder = RequestRecorder()
let transport = StubHTTPTransport { request in
    await recorder.record(request)
    return .json(#"{"status": "active"}"#)
}

_ = try await provider.validate(record)
#expect(await recorder.last?.url.path == "/v1/licenses/check")
```

Save real response bodies from the provider's sandbox into fixtures and decode
them in tests. When the provider changes a field, your tests fail before your
customers do.

Worth covering explicitly:

- [ ] A successful activation maps every field you rely on.
- [ ] A refunded/revoked response produces `.revoked`.
- [ ] An unrecognised status produces `.unknown`, not `.active`.
- [ ] A 404 produces `.licenseNotFound`.
- [ ] A 5xx is transient; a rejection is not.
- [ ] A response with extra unknown fields still decodes.
- [ ] A response missing every optional field still decodes.

## Custom transports

```swift
struct PinnedTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // your networking stack, certificate pinning, proxy, shared queue…
    }
}
```

`OfflineHTTPTransport` throws `.unreachable` on every call — useful for a build
that must be provably offline, and as an explicit default so a misconfiguration
fails loudly instead of making a surprise network call.

## Multiple providers

```swift
providers: [gumroad, polar, ownBackend]
```

Records remember their origin, so `refresh()` and `deactivate()` always go back to
the provider that issued them. `activate` picks the first that supports it unless
you name one — so put your primary first, and let the customer choose when a key
could plausibly come from either store.

## Next

- [Validation](validation.md) — how `providerState` is enforced
- [Recipes](recipes.md) — seat management and migration flows
- [Architecture](architecture.md#3-the-five-seams) — why the seam is shaped this way
