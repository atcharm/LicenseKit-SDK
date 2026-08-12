# Recipes

Complete, working patterns for the situations that actually come up.

## A self-issued trial

The app mints its own trial on first launch. No server, no signup.

```swift
import LicenseKit
import LicenseKitVendor   // ⚠️ see the warning below

func startTrialIfNeeded(_ licensing: LicenseManager) async throws {
    guard await licensing.state == .unlicensed else { return }

    let issuer = LicenseIssuer(signingKey: trialSigningKey)
    let signed = try issuer.issue(
        .trial(
            product: ProductReference(id: "com.example.app"),
            issuer: "com.example.app.trial",
            expiresAt: Date().addingTimeInterval(.licenseDays(14)),
            entitlements: [Entitlement(id: "export.pdf")]
        )
    )
    try await licensing.install(signed)
}
```

> **This ships a signing key inside your app.** Use a *separate* key pair whose
> public half is trusted only for trials — never your production issuing key.
> Someone who extracts the trial key can mint infinite trials, which is a
> tolerable outcome. Someone who extracts your production key can mint infinite
> paid licenses, which is not.

Distinguish the two at validation time by issuer:

```swift
ClosureRule(id: "trial.issuer") { context in
    let isTrialKey = context.record.signature?.keyID == "trial-key"
    let claimsTrial = context.license.policy.kind == .trial
    // A trial key must not be able to sign a non-trial license.
    return isTrialKey && !claimsTrial
        ? .failed(.custom(rule: "trial.issuer", message: "invalid license"))
        : .satisfied
}
```

Make the trial resistant to a clock reset:

```swift
timeAnchor: UserDefaultsTimeAnchor()
```

And to a reinstall, if you care, by keying it to something that survives — though
be honest that on iOS this means the Keychain, which brings its own
[trade-off](storage.md#the-reinstall-trade-off). Most products accept that a
determined user gets a second trial.

## Subscription with a grace period

```swift
LicenseSpecification.subscription(
    product: ProductReference(id: "com.example.app"),
    issuer: "com.example.licensing",
    expiresAt: renewalDate,
    entitlements: [Entitlement(id: "sync.cloud", limit: 5)],
    seats: 5,
    offlineGrace: .licenseDays(30),   // a customer on a plane keeps working
    expiryGrace: .licenseDays(3)      // a failed card retry is invisible
)
```

Refresh so a renewal is picked up promptly without hammering the API:

```swift
refreshPolicy: RefreshPolicy(
    refreshesOnStart: true,
    minimumInterval: .licenseHours(6),
    eagerRefreshWindow: .licenseDays(3)   // ignore the rate limit near expiry
)
```

`eagerRefreshWindow` is what stops the "I paid yesterday and it still says
expired" ticket: inside the window, the rate limit is bypassed.

Surface grace rather than hiding it:

```swift
if case .licensed(_, let report) = model.state, report.isRunningOnGrace {
    banner(report.summary, action: .openBilling)
}
```

## Seat management UI

```swift
struct SeatView: View {
    let licensing: LicenseManager
    @State private var canRelease = false

    var body: some View {
        VStack {
            if canRelease {
                Button("Deactivate this device") {
                    Task { try? await licensing.deactivate() }
                }
            }
        }
        .task {
            // Only offer what the provider can actually do. Gumroad has no
            // seat-release endpoint, so this button never appears there.
            canRelease = await licensing.record.map { record in
                configuration.providers
                    .first { $0.providerID == record.origin.provider }?
                    .capabilities.contains(.deactivation) ?? false
            } ?? false
        }
    }
}
```

Handle the ceiling explicitly, because "activation failed" is not an actionable
message:

```swift
do {
    try await licensing.activate(key: key)
} catch LicenseKitError.provider(.seatLimitReached) {
    showSeatLimitHelp()      // "release another device, or upgrade"
} catch {
    showGeneric(error)
}
```

And plan for the device that never releases its seat — dropped in a river, wiped,
sold. Either enable `reclaimsOldestSeat`, or make sure support can release seats
from your dashboard. Otherwise every lost laptop is a permanently burned seat.

## A site license distributed by MDM

An administrator deploys one signed file to hundreds of machines.

**Issue it:**

```sh
licensekit issue \
  --signing-key-file ./keys/vendor-2026.private --key-id vendor-2026 \
  --product com.example.studio --issuer com.example.licensing \
  --kind site --organization "Acme, Inc." --seats 500 \
  --expires 2028-01-01 --offline-grace 90 \
  --entitlements "export.pdf|sso" \
  --out acme-site.license
```

**Read it from a managed location:**

```swift
let managedURL = URL(fileURLWithPath: "/Library/Application Support/Example/site.license")

if FileManager.default.fileExists(atPath: managedURL.path) {
    let licenses = try LicenseFileReader().read(contentsOf: managedURL)
    try await licensing.install(licenses[0])
}
```

Ninety days of offline grace is not excessive here — air-gapped and heavily
firewalled fleets are exactly where site licenses get sold.

Note there is no per-device activation: every machine installs the same license
and `MachineBindingRule` reports itself not applicable. That is the intent. Seat
counting for a site license happens in the contract, not in the software.

## Bundled licenses from a CSV manifest

For volume purchases where each user gets their own key.

```swift
let source = CSVLicenseSource(
    contentsOf: manifestURL,
    decoder: CSVLicenseDecoder(
        defaultProduct: "com.example.app",
        issuer: "com.example.licensing"
    ),
    skipsInvalidRows: true    // one bad row must not break the whole fleet
)

let configuration = LicenseKitConfiguration(
    product: "com.example.app",
    verifier: verifier,
    store: store,
    providers: [OfflineLicenseProvider(source: source)],
    validator: .connectedDefault()
)

try await licensing.activate(key: userEnteredKey)
```

The table is **unsigned**, so this is only appropriate when the file reaches the
device through a channel you control. For anything a customer can reach, sign the
table first — see [issuing.md](issuing.md#issuing-from-a-csv-table).

## Feature gating patterns

Keep the licensing check at the edge of your feature code, not threaded through it.

```swift
@MainActor @Observable
final class Entitlements {
    private(set) var canExportPDF = false
    private(set) var deviceLimit = 1

    func track(_ licensing: LicenseManager) async {
        for await state in await licensing.stateUpdates() {
            canExportPDF = state.isEntitled(to: "export.pdf")
            deviceLimit = state.limit(for: "sync.cloud") ?? 1
        }
    }
}
```

```swift
Button("Export PDF") { export() }
    .disabled(!entitlements.canExportPDF)
```

For a paywall that explains itself:

```swift
struct Locked<Content: View>: View {
    let entitlement: EntitlementID
    let state: LicenseState
    @ViewBuilder let content: () -> Content

    var body: some View {
        if state.isEntitled(to: entitlement) {
            content()
        } else {
            UpgradePrompt(reason: state.failures.first?.description)
        }
    }
}
```

Passing the reason through means an expired subscriber sees "renew" rather than
"upgrade" — a distinction that costs nothing here and converts very differently.

## Background refresh

```swift
// iOS — BGAppRefreshTask
func handleRefresh(_ task: BGAppRefreshTask) {
    let work = Task {
        await licensing.refreshQuietly()   // never throws
        task.setTaskCompleted(success: true)
    }
    task.expirationHandler = { work.cancel() }
}
```

Use `refreshQuietly()` on background paths. It swallows errors by design — a
background refresh has no user to tell, and a transient failure must not change
state.

Pair with `.afterFirstUnlock` keychain accessibility if you use the Keychain, or
the refresh fails whenever the screen happens to be locked.

## Migrating from another SDK

Convert the old state into a `LicenseRecord` once, at launch.

```swift
func migrateIfNeeded(_ licensing: LicenseManager, store: any LicenseStore) async throws {
    guard try await store.loadAll().isEmpty,
          let legacy = LegacySDK.storedLicense()
    else { return }

    let license = License(
        // Derive the ID rather than generating one, so a repeated migration
        // is idempotent.
        id: LicenseID("legacy:\(legacy.key)"),
        key: LicenseKey(legacy.key),
        product: ProductReference(id: "com.example.app"),
        subject: LicenseSubject(email: legacy.email),
        policy: LicensePolicy(
            kind: legacy.isSubscription ? .subscription : .perpetual,
            validity: ValidityWindow(expiresAt: legacy.expiry)
        ),
        entitlements: EntitlementSet(legacy.features.map {
            Entitlement(id: EntitlementID(rawValue: $0))
        }),
        issuance: IssuanceInfo(issuer: "com.example.migration", issuedAt: legacy.purchasedAt)
    )

    try await store.save(LicenseRecord(
        license: license,
        origin: LicenseOrigin(provider: .local, medium: .selfIssued, retrievedAt: Date()),
        providerState: ProviderStateSnapshot(status: .unknown),
        lastValidatedAt: Date()
    ))
    await licensing.start()
}
```

Migrated records have **no signature**, so validate them with
`SignatureRule(policy: .requiredWhenPresent)`. Two ways forward:

**Re-activate against your provider.** Cleanest — the customer's key is exchanged
for a properly signed license, and the migrated record is replaced.

**Re-issue server-side.** Have your backend accept a legacy key and return a
signed license. Better UX, more backend work.

Do not leave migrated records unsigned indefinitely: at that point anyone can
hand-write one.

## Multiple products in one app

One manager per product, sharing a store:

```swift
let core = LicenseManager(configuration: config(product: "com.example.core"))
let pro  = LicenseManager(configuration: config(product: "com.example.proPack"))
```

Each rejects the other's licenses via `ProductRule`, which is exactly what you
want for separately-sold modules.

## Testing your integration

```swift
@Test func expiredSubscriptionShowsRenewal() async throws {
    let keys = try LicenseSigningKey.generate(id: "test")
    let clock = FixedLicenseClock(Date(timeIntervalSince1970: 1_800_000_000))

    let signed = try LicenseIssuer(signingKey: keys.signing, clock: clock).issue(
        .subscription(
            product: ProductReference(id: "com.example.app"),
            issuer: "test",
            expiresAt: clock.now.addingTimeInterval(-.licenseDays(1))
        )
    )

    let manager = LicenseManager(configuration: LicenseKitConfiguration(
        product: "com.example.app",
        verifier: CryptoKitLicenseVerifier(key: keys.verification),
        clock: clock
    ))

    await #expect(throws: LicenseKitError.self) { try await manager.install(signed) }
}
```

Move time by constructing a new `FixedLicenseClock` rather than sleeping:

```swift
let later = FixedLicenseClock(clock.now.addingTimeInterval(.licenseDays(40)))
```

Simulate an outage with a throwing transport:

```swift
StubHTTPTransport { _ in throw LicenseProviderError.unreachable(reason: "test") }
```

Worth testing in your own app:

- [ ] Fresh install, valid license → licensed.
- [ ] Fresh install, expired license → renewal path.
- [ ] Relaunch preserves the license.
- [ ] Expiry between launches → invalid, with the record retained.
- [ ] Offline inside grace → still works.
- [ ] Offline past grace → stops, with a reconnect message.
- [ ] Revoked upstream → locked within the grace window.
- [ ] Seat limit reached → seat-management UI, not a generic error.
- [ ] Tampered file → rejection, no crash.

## Next

- [Licensing model](licensing-model.md) — modelling decisions behind these
- [Providers](providers.md) — connecting a store
- [Troubleshooting](troubleshooting.md) — when one of these does not behave
