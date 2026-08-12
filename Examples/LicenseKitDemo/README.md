# Aperture — a LicenseKit demo

A running macOS app that integrates LicenseKit through its public API, plus the
integration tests an app of this shape should have. It licenses a fictional photo
editor called Aperture.

```sh
cd Examples/LicenseKitDemo
swift run LicenseKitDemo    # the app
swift test                  # 50 integration tests, no network, no sleeping
```

The first build downloads about 57 MB of release XCFrameworks — they are fat
binaries covering every supported platform and simulator — so give it a few
minutes on a fast connection, considerably longer on a slow one. Subsequent builds
reuse `.build/artifacts`.

This demo integrates the SDK **exactly the way you will** — through the prebuilt
XCFrameworks published with each release, with no source checkout and no
privileged access. If it builds for you, your own app will too.

There is no licensing server. A stand-in service runs in-process and answers
through the real `RemoteLicenseProvider` over a substituted `HTTPTransport`, so
every retry, backoff, and error mapping in the SDK actually executes.

## Depending on the SDK from your own app

The demo resolves the distribution package two directories up, so it always
matches the release it shipped in. Your app uses the URL form:

```swift
dependencies: [
    .package(url: "https://github.com/gumbracelet/LicenseKit-SDK.git", from: "1.0.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "LicenseKit", package: "LicenseKit")
    ])
]
```

One product, `LicenseKit`, gets you the umbrella module and everything it
re-exports — `LicenseKitCore`, `Crypto`, `Formats`, `Storage`, `Providers`. A
single `import LicenseKit` is all the app target needs.

`LicenseKitVendor` is a **deliberately separate product**. It holds the type that
signs licenses, so linking it into a shipping app would ship the ability to mint
licenses for your own product. Depend on it from your issuing tool only. In this
demo, `DemoBackstage` is that issuing tool.

## The two targets, and why they are separate

| Target | Links | What it is |
|---|---|---|
| `LicenseKitDemo` | `LicenseKit` | The app. The only code here you should copy. |
| `DemoBackstage` | `LicenseKit`, `LicenseKitVendor` | Your fulfilment backend. Runs on a server you control. |

`DemoBackstage` holds a **private signing key**. Anything that can call it can
mint licenses for the product. It is a separate target so that linking it into a
shipping app requires a deliberate act — and the demo only gets away with it
because it needs to be self-contained.

## Where to start reading

`Sources/LicenseKitDemo/DemoRuntime.swift` → `DemoRuntime.make(setup:…)`.

That one function is the whole integration: store, verifier, rule chain, machine
identity, provider, refresh policy, clock. Nothing else in the app constructs any
of them. The rest of the app is user interface for poking at it, and
`LicensingModel.swift` is the piece worth copying second — it mirrors
`LicenseState` into an `@Observable` and funnels every call through one method
that owns the loading flag and the error presentation.

## The screens

- **Status** — what the SDK believes, and the rule-by-rule `ValidationReport`
  that says why. Each failure is paired with the remedy it actually calls for.
- **Activate** — redeem a key. Lists the keys the service knows, and the
  capabilities the provider advertises.
- **License files** — twelve signed licenses minted on demand, one per situation
  a support queue produces. Install, copy as text, or save to disk.
- **Features** — entitlement gates, live.
- **Service** — make the backend slow, flaky, unreachable, rate-limited,
  unauthorized, or malformed. Revoke, lapse, renew, and steal seats.
- **Setup** — the configuration, rebuilt live. Also time travel.
- **Activity** — SDK, service, and app diagnostics interleaved.

## Things worth doing, in order

1. **Activate** `APERT-STUDIO-MONTHLY`. Watch Features unlock.
2. **Setup → +30 days.** The subscription crosses into its warning window, then
   its expiry grace, then expires. Status explains each step.
3. **Service → Revoke** that key, then **Refresh**. The license goes invalid with
   `revoked`. Note that `refresh()` did not throw — the provider answered
   clearly, and a clear answer is not an error.
4. **Service → No network**, then **Refresh** again. Nothing is revoked. A
   transient failure must never look like a revocation.
5. **Service → Take a seat** on `APERT-STANDARD-SOLO`, then activate it.
   `seatLimitReached`, distinct from "no such key".
6. **License files → Edited after signing.** Rejected on the signature, before
   any other rule gets a say. This is the forgery the whole design exists to
   defeat.
7. **License files → Signed by a key you don't trust.** Rejected as
   `unknownSigningKey`, *not* `signatureInvalid` — so the app can say "update the
   app" rather than "this is forged".
8. **Setup → uncheck "Report the real fingerprint"**, Apply. An activated license
   now fails `machineMismatch`.
9. **Setup → Signatures: Disabled**, Apply, then install the tampered file. It
   works, and grants `everything.forever`. That is why the screen marks it as
   never shippable.
10. **Quit and relaunch.** The file store restores the license. Switch to the
    in-memory store and it does not.

## Behaviour that surprises people

**A rejected install leaves the state `.invalid`, not `.unlicensed`.** The record
is kept in memory so the UI can show *which* license failed, but it is never
written — so the next launch starts clean. `LicenseKit` refuses to persist a
license it would reject on every launch, because that produces a permanently
broken install with no way out.

**`refresh()` throws only on a definitive rejection.** Revoked, not found, seat
limit. A timeout or a 503 returns a state computed from the cached record and lets
the grace rules decide. This is the difference between "let the paying customer
keep working on a plane" and "let a refunded license run forever".

**`deactivate()` removes the local record even when the provider call fails,**
then rethrows. A user who asked to sign out must end up signed out; a stranded
remote seat is recoverable through a dashboard, an app that refuses to forget a
license is not.

**A file-delivered subscription needs `offlineDefault()`.**
`LicenseSpecification.subscription` defaults to a 30-day offline grace, which is
right when a provider backs it. Pair that license with `connectedDefault()` and
it will eventually fail `offlineGraceExhausted` — a rule it cannot cure, because a
file has no provider to check in with. The demo warns about this on the License
files screen.

**Never put a `Date` in signed metadata.** `MetadataValue.date` canonicalises as
an integer but its JSON form is an ISO-8601 string, and the decoder cannot tell
that string from any other — so it returns as `.string`, the canonical bytes
differ, and the signature never verifies. Store the timestamp as text instead;
`DemoLicenseFactory` has the note. (`Date` fields on `License` itself are fine —
they are floored to whole seconds precisely so this cannot happen.)

## The tests

`swift test` covers what the SDK's integration guide asks for, and links no user
interface — every non-deterministic input is injectable, so there is no network
and no sleeping.

| Suite | Covers |
|---|---|
| `Provider flows` | Activation, seats, deactivation, refunds, rate limits, retries, revocation, renewal, unsigned providers |
| `Offline license files` | Every scenario the factory mints, plus text round-tripping and version bounds |
| `Lifecycle` | Persistence across relaunch, expiry between launches, expiry and offline grace, clock rollback, machine binding, state observation |

`Tests/LicenseKitDemoTests/DemoHarness.swift` is the setup shape to copy: a
movable clock, an in-memory store, an in-process transport, and a fixed
fingerprint.

## One thing the binary distribution changes

The XCFrameworks are built with **library evolution** enabled. That is what lets
you drop in a new release without recompiling, and it has exactly one consequence
for your code: a `switch` over a public enum that is not `@frozen` needs an
`@unknown default` clause, because a future release could add a case.

Which enums are frozen is a deliberate part of the API. These are, so you can
switch over them exhaustively and the switch stays valid forever:

`LicenseState`, `RuleOutcome`, `Connectivity`, `MetadataValue`, `JSONValue`,
`SignatureRule.Policy`, `LicenseValidator.Strategy`, `LicenseLogLevel`,
`HTTPRequest.Method`.

These are open, and will grow: `ValidationFailureReason`, `ValidationWarning`,
`LicenseProviderError`, `LicenseKitError`, `LicenseFormatError`,
`LicenseStorageError`, `LicenseCryptoError`.

This demo writes a plain `default:` rather than `@unknown default:` on every one
of the open enums — see `Presentation.swift`, which switches over four of them.
`default:` compiles in both tiers, so the code is portable if you ever move
between the source and binary distributions. `@unknown default:` is the stricter
choice: it warns you when a new case appears, which is usually what you want in
your own app.

Note also that the *identifier* types — `ProviderStateSnapshot.Status`,
`LicenseKind`, `SignatureAlgorithm`, `RuleIdentifier`, `LicenseOrigin.Medium` —
are structs, not enums, for the same reason. A provider can introduce a status the
core has never heard of without a breaking change, and decoding an unknown value
never fails. Switching over them always needs a `default`.

## Caveats of running as a SwiftPM executable

This is a plain binary, not an `.app` bundle. Two consequences, neither of which
applies to a real app:

- `DemoAppDelegate` calls `NSApp.setActivationPolicy(.regular)` so the app gets a
  Dock icon and keyboard focus.
- There is no `Info.plist`, so `SemanticVersion.fromMainBundle()` returns `nil`
  and `VersionBoundRule` would be inapplicable. The Setup screen supplies a
  version by hand instead.

The **Keychain** store is offered in Setup but an unsigned binary is usually
refused by the data-protection keychain (`errSecMissingEntitlement`). The demo
surfaces the storage error rather than hiding it; use the file store here, and the
keychain in a real signed app.

## The keys in this demo are worthless

`DemoVendorKeys` is published in a public example. It signs licenses for a product
that does not exist, trusted only by this demo. Generate your own:

```sh
licensekit keygen --key-id vendor-2026 --out ./keys
```
