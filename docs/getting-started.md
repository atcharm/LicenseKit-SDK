# Getting started

By the end of this page you will have generated a key pair, issued a real signed
license, and gated a feature on it.

## Install

Add the package in Xcode via **File ▸ Add Package Dependencies…** with
`https://github.com/gumbracelet/LicenseKit-SDK.git`, or declare it in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gumbracelet/LicenseKit-SDK.git", from: "1.0.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "LicenseKit", package: "LicenseKit-SDK")
    ])
]
```

`LicenseKit` is the umbrella product and re-exports everything an app needs. If you
want a narrower surface, the layers are individually available — see
[architecture.md](architecture.md#2-layering).

LicenseKit ships as prebuilt XCFrameworks, statically linked, so there is nothing
to embed and nothing to sign. One API note comes with that: the frameworks are
built with library evolution enabled, so a `switch` over a public enum that is not
`@frozen` — the error and failure-reason taxonomies — needs an `@unknown default`
case. The types you branch on daily, `LicenseState` among them, are `@frozen` and
switch exhaustively.

### Installing the `licensekit` tool

The steps below use `licensekit`, the vendor-side command line tool. You need it to
*issue* licenses; an app that only validates them does not. It is attached to every
release:

```sh
curl -fsSLO https://github.com/gumbracelet/LicenseKit-SDK/releases/download/1.0.0/licensekit.artifactbundle.zip
unzip -q licensekit.artifactbundle.zip
install licensekit.artifactbundle/licensekit-1.0.0-macos/bin/licensekit /usr/local/bin/
licensekit --help
```

macOS only, signed with a Developer ID. If you would rather issue licenses from
your own Swift backend, the `LicenseKitVendor` product is the same code as a
library — see below.

### The one import that must never reach your app

```swift
.product(name: "LicenseKitVendor", package: "LicenseKit-SDK")   // issuing tools ONLY
```

`LicenseKitVendor` contains `LicenseSigningKey` — the private half of your identity
as a vendor. Anyone holding those bytes can mint licenses for your product that
your app will happily accept.

It is a separate target so that shipping it requires editing a dependency list,
not accepting an autocomplete. Put it in your fulfilment backend or a build script,
never in an app target.

## Step 1 — Generate your vendor keys

Once, ever, for the lifetime of the product:

```sh
licensekit keygen --key-id vendor-2026 --out ./keys
```

You get two files:

| File | Secret? | Where it goes |
|---|---|---|
| `vendor-2026.public` | No | Embedded in your app |
| `vendor-2026.private` | **Yes** | Your issuing server or a secrets manager |

The public key discloses nothing and cannot forge anything, so embedding it in a
binary, a plist, or a public repo is entirely safe.

The private key is different, in a way worth internalising now:

- **Leak it** and anyone can issue licenses for your product. Recovering means
  shipping an app update with a new key and reissuing every outstanding license.
- **Lose it** and you can never issue another license that already-shipped apps
  accept. There is no recovery. Back it up somewhere you trust.

Add `--sealing` if you also want a symmetric key to encrypt license files. Read
[the sealing section](issuing.md#sealing) before you decide you need it — the
honest answer is usually that you do not.

## Step 2 — Issue a license

From the command line:

```sh
licensekit issue \
  --signing-key-file ./keys/vendor-2026.private \
  --key-id vendor-2026 \
  --product com.example.app \
  --issuer com.example.licensing \
  --kind subscription \
  --expires 2027-06-30 \
  --seats 3 \
  --entitlements "export.pdf|sync.cloud" \
  --name "Jane Smith" --email jane@example.com \
  --offline-grace 30 \
  --out jane.license
```

Or from your own fulfilment code, which is what you will actually ship:

```swift
import LicenseKitVendor

let issuer = LicenseIssuer(signingKey: signingKey)

let signed = try issuer.issue(
    .subscription(
        product: ProductReference(id: "com.example.app", name: "Example App"),
        issuer: "com.example.licensing",
        expiresAt: renewalDate,
        subject: LicenseSubject(name: order.customerName, email: order.email),
        entitlements: [Entitlement(id: "export.pdf")],
        seats: 3
    )
)

let fileData = try issuer.package(signed)     // binary, to attach to an email
let pasteable = try issuer.issueText(spec)    // base64 text, to paste in a field
```

`.subscription` is a convenience; `.perpetual` and `.trial` exist too, and you can
build a `LicenseSpecification` field by field for anything else. See
[licensing-model.md](licensing-model.md).

Look at what you made:

```sh
licensekit inspect --in jane.license
```

## Step 3 — Validate it in your app

```swift
import LicenseKit

let configuration = try LicenseKitConfiguration.offline(
    product: "com.example.app",
    publicKeys: [(id: "vendor-2026", base64: embeddedPublicKey)],
    store: try FileLicenseStore.applicationSupport(subdirectory: "com.example.app"),
    fingerprintSalt: "example-app-2026"
)

let licensing = LicenseManager(configuration: configuration)
```

Then, once during launch:

```swift
await licensing.start()
```

`start()` loads any stored license, re-runs every validation rule against it, and
publishes the result. It never throws — a launch path must produce *some* state,
and an app that crashes because its licensing store is corrupt is worse than one
that reports itself unlicensed and offers a button.

`fingerprintSalt` is any fixed, product-specific string. It need not be secret,
only distinct: it is what stops the device fingerprint you store being
correlatable with the one another vendor stores for the same machine.

## Step 4 — Install a license the customer received

```swift
do {
    try await licensing.installLicenseFile(fileData)
} catch let error as LicenseKitError {
    show(error.localizedDescription)
}
```

Or from pasted text:

```swift
let signed = try LicenseFileReader().read(base64Text: pastedText)
try await licensing.install(signed[0])
```

A license that fails validation is **not persisted**. Storing one your app rejects
on every launch produces a permanently broken install with no obvious way out, so
`install` throws instead and leaves the previous state alone.

## Step 5 — Gate features

```swift
if await licensing.isEntitled(to: "export.pdf") {
    enablePDFExport()
}

// Capabilities can carry a numeric ceiling.
let deviceLimit = await licensing.limit(for: "sync.cloud") ?? 1
```

`isEntitled(to:)` returns `false` when the license is absent **or invalid**. That
is deliberate: the failure mode of forgetting a status check is a paywall bypass,
so the safe answer is built into the call rather than left to your discipline.

## Step 6 — Show the state

`LicenseState` has three cases, and the third is the one people forget.

```swift
@MainActor @Observable
final class LicenseModel {
    private(set) var state: LicenseState = .unlicensed

    func observe(_ licensing: LicenseManager) async {
        // Yields the current state immediately, then every change.
        for await state in await licensing.stateUpdates() {
            self.state = state
        }
    }
}
```

```swift
switch model.state {
case .unlicensed:
    ActivationView()

case .licensed(_, let report) where report.isRunningOnGrace:
    // Valid, but on borrowed time — expiring soon, past expiry inside grace,
    // or overdue for an online re-check. Say so; do not block.
    ContentView().banner(report.summary)

case .licensed:
    ContentView()

case .invalid(_, let report):
    // The record is retained so you can name which license failed.
    ProblemView(message: report.summary, reasons: report.failures)
}
```

Branch on `report.failures` to offer the right remedy — see
[validation.md](validation.md#acting-on-failures).

## Five things that trip people up

**`start()` is not optional.** `refresh()`, `deactivate()`, and `state` all operate
on state that `start()` loads. Skip it and a manager with a perfectly good stored
license reports `.unlicensed`, and `refresh()` throws `.noActiveLicense`.

**Public key in the app, private key nowhere near it.** If you find yourself
putting a `.private` file into a bundle to make something work, stop — the thing
you actually wanted was `--public-key`.

**Don't gate on `license.policy.kind`.** Gate on entitlements. Kinds are marketing
categories that change with pricing; entitlements are capabilities that do not.
Code that says `if kind == .pro` has to be rewritten every time sales invents a
tier.

**Don't check expiry yourself.** `license.isWithinValidity(at:)` exists for
display, and using it as a gate silently skips signature verification, revocation,
seat limits, and grace. Route gates through `isEntitled(to:)`.

**A CSV table is not signed.** Anyone who can edit the file can grant themselves a
license. That is fine for a fleet where the file arrives by MDM, and wrong for
public distribution — see [issuing.md](issuing.md#issuing-from-a-csv-table).

## Verification checklist

Each item is a bug the type system cannot catch, and several only appear in front
of a real customer.

- [ ] `swift build && swift test` clean.
- [ ] A freshly issued license installs and unlocks the right features.
- [ ] Editing one byte of the license file causes a rejection, not a crash.
- [ ] A license signed by a *different* key is rejected.
- [ ] A license for a *different* product is rejected.
- [ ] Quitting and relaunching keeps the license — `start()` restores it.
- [ ] An expired license shows a renewal path, not a blank unlicensed screen.
- [ ] Aeroplane mode: the app still runs (offline grace) if that is your policy.
- [ ] Aeroplane mode past the grace window: it stops, with a clear message.
- [ ] Wind the system clock back a year: rollback is detected.
- [ ] No license key or customer email appears in your logs or crash reports.
- [ ] Your app binary contains **no** private signing key: `strings YourApp | grep -c "$(cat keys/vendor-2026.private)"` prints `0`.
- [ ] Revoking a license upstream reaches the app within your grace window.

Anything failing here is likely in [troubleshooting.md](troubleshooting.md).

## Next

- [Licensing model](licensing-model.md) — how to model your actual pricing
- [Providers](providers.md) — connect Gumroad, Polar, or your own backend
- [Issuing](issuing.md) — key rotation, sealing, CSV import, full CLI reference
- [Recipes](recipes.md) — trials, seat management, migration
