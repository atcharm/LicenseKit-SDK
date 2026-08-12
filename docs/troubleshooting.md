# Troubleshooting

Symptom → cause → fix. Licensing bugs rarely point at their cause, and several
only appear in front of a real customer. Start here before debugging from first
principles.

## Signatures

### A license verifies on my machine but not on a customer's
Almost always a key mismatch: the app is verifying against a different public key
than the one whose private half signed the license. The report says
`.unknownSigningKey` for a key ID the app does not hold, or `.signatureInvalid`
for a key ID it holds but that did not sign this.
**Fix:** confirm the embedded public key matches the signing key —
`licensekit keygen` prints both halves, and `LicenseSigningKey.verificationKey()`
recovers the public half from a private key so you can diff them.

### `.signatureInvalid` on a license I just issued
The bytes changed between signing and verification. Run
`licensekit canonical --in the.license` on both the issuing machine and the
verifying one and diff the output — the answer is always visible there.
**Fix:** the usual culprit is a `License` mutated *after* signing. The signature
covers the claim set at the moment it was signed; changing any signed field
afterwards invalidates it.

### Verification fails only for licenses issued by my backend, not by the CLI
Your backend is probably constructing dates with sub-second precision through a
path that bypasses the model initialisers.
**Fix:** dates in signed models are floored to whole seconds by
`ValidityWindow` and `IssuanceInfo`. If you build a `License` by decoding
hand-rolled JSON, route it through those initialisers rather than assigning
stored properties by reflection or a custom decoder that skips them.

### `.signatureMissing` on a license that clearly has a signature
`SignatureRule(policy: .required)` reports this when a signature is present but no
verifier is configured — a configuration error must not become a silent pass.
**Fix:** set `verifier:` on your `LicenseKitConfiguration`. `RejectingVerifier` is
the fail-closed default and accepts nothing.

### `.unsupportedAlgorithm` after adding a P-256 key
A key is bound to one algorithm at registration, and a signature claiming a
different one is rejected rather than dispatched on — that is deliberate, because
honouring the signature's own claim would let an attacker choose the verification
path.
**Fix:** register the verification key with the algorithm it was generated for.

### Every license fails after I rotated keys
The app only trusts the old key.
**Fix:** `CryptoKitLicenseVerifier(keys: [old, new])`. Ship the app trusting both
*before* you start signing with the new one — rotation is not retroactive.

## Files

### "not a LicenseKit envelope"
The file is not a container — often base64 text saved with a `.license`
extension, or a truncated download.
**Fix:** `LicenseFileReader.read(contentsOf:)` accepts either form. If you are
calling `read(_ data:)` directly with text, use `read(base64Text:)`.

### "the license is encrypted but no decryption key is configured"
The file was sealed at issuance; the reader has no unsealer.
**Fix:** `LicenseFileReader.sealed(key: sealingKey)`, or stop sealing —
[unsealed signed licenses are a sound choice](security.md#sealing-is-not-authentication).

### "the license could not be decrypted"
Wrong sealing key, a corrupted byte, or an edited header. The error is
deliberately uniform so it does not help an attacker distinguish those.
**Fix:** confirm the sealing key matches the one used to issue. Re-download the
file before assuming tampering — truncated downloads look identical.

### A customer's pasted license text fails to parse
Mail clients wrap, quote, and prefix pasted blocks.
**Fix:** the reader already strips whitespace. If it still fails, the text is
genuinely truncated — mail clients also *cut* long blocks. Send a file attachment
instead, or use `issueText(lineLength:)` with shorter lines.

### "the file holds N licenses; use read(_:) instead"
`readOne` deliberately refuses a bundle rather than silently taking the first.
**Fix:** use `read(_:)` and choose, or issue single-license files.

### "license container version N is newer than this build supports"
The file was produced by a newer LicenseKit than the app links.
**Fix:** update the app. This message exists so that case reads as "needs a newer
version" rather than crashing on a malformed parse.

## Validation

### `isEntitled(to:)` returns false for a license I can see is valid
Three common causes, in order of likelihood.
**Fix:** check `state.failures` — the license may be `.invalid` rather than
`.licensed`. Confirm the entitlement ID matches *exactly*, including case. And
confirm `start()` was called; before it, state is `.unlicensed`.

### Everything is `.unlicensed` even though a license is stored
`start()` was never called. It is what loads the store.
**Fix:** `await licensing.start()` once during launch.

### `refresh()` throws `.noActiveLicense` with a license in the store
Same cause. `refresh()` operates on loaded state, not on the store.
**Fix:** call `start()` first.

### `.productMismatch` on a license issued for this product
The `ProductID` string differs — usually a typo, a case difference, or the store's
product ID used where yours belongs.
**Fix:** compare `configuration.product` against `license.product.id` exactly. In
an adapter, `product:` is *your* identifier and `productID:` is the store's; they
are separate parameters on purpose.

### Licenses expire a day early or late
A date-only string like `2027-06-30` parses as midnight **UTC**, not local time.
**Fix:** for a term that should end at end-of-day locally, issue an explicit
timestamp rather than a date. Add the grace period you almost certainly want
anyway.

### `.expired` immediately after a customer renewed
The app has not refreshed, so it is still reading the signed expiry.
**Fix:** set `eagerRefreshWindow` on `RefreshPolicy` so refreshes bypass the rate
limit near expiry. Confirm the provider is returning the new date in
`providerState.expiresAt`, which supersedes the signed one.

### `SeatLimitRule` never fires
It reports itself **not applicable** without a provider that supplies
`activationCount`. A local device cannot know what other machines are doing, and
guessing would be worse than not checking.
**Fix:** expected behaviour offline. Ensure your adapter populates
`providerState.activationCount`.

### `MachineBindingRule` never fires
Same shape: inapplicable when the record has no `activation`. An unbound license
is a legitimate configuration.
**Fix:** ensure your adapter sets `activation` when a fingerprint is supplied, and
that `machineIdentity` is configured — the default `StaticMachineIdentity("unbound")`
is a placeholder.

### `VersionBoundRule` never fires
`applicationVersion` is `nil`, which is the case outside an app bundle — including
in tests and command-line tools.
**Fix:** expected in tests. In an app, confirm `CFBundleShortVersionString` is
present and parses as a semantic version. Pass it explicitly if your scheme is
unusual.

### Clock tampering fires for an honest user
Their clock was genuinely wrong and got corrected, or the tolerance is too tight.
**Fix:** raise `ClockTamperRule(tolerance:)`. One day is the default; anything
under a few hours will produce false positives on real hardware.

### Clock tampering never fires
No `timeAnchor` is configured, so the rule is inapplicable.
**Fix:** `timeAnchor: UserDefaultsTimeAnchor()`. `InMemoryTimeAnchor` only detects
tampering within a single session.

## Providers

### Activation fails with a network error that is really a rejection
Your adapter's `mapFailure` is classifying a definitive answer as transient.
**Fix:** check `error.isTransient`. Only `unreachable`, `timedOut`, `rateLimited`,
and `server` should be transient. Mapping a rejection to `.unreachable` lets a
refunded license run forever.

### Customers are deactivated by flaky Wi-Fi
The inverse: a transient failure is being classified as definitive.
**Fix:** the runtime only revokes on a definitive answer, so this is an adapter
mapping bug. A timeout must not map to `.rejected`.

### Gumroad seat count keeps climbing
`incrementUsesCount` is true on validation, so every launch consumes a "use".
**Fix:** it defaults to `false` for exactly this reason. Increment only at genuine
activation.

### `.unsupportedOperation` when deactivating
The provider does not advertise `.deactivation` — Gumroad, for instance, has no
seat-release endpoint.
**Fix:** check `capabilities.contains(.deactivation)` before offering the button.
Use `removeLicense()` to forget locally without a provider call.

### Polar deactivation fails with "no activation to release"
The record has no `activation.id`, usually because activation ran without a
fingerprint.
**Fix:** ensure `machineIdentity` is configured so `ActivationRequest` carries a
fingerprint. Without one, there is no seat to name.

### An adapter breaks after the provider changes its API
A field was renamed or its type changed.
**Fix:** `JSONValue` degrades rather than throwing, so the symptom is usually a
`nil` field rather than an error. Save real response bodies as test fixtures so
this fails in CI instead of in production.

### Retries hammer the API
`maximumRetries` too high, or definitive errors being retried.
**Fix:** only transient failures retry. Check your `mapFailure`. `RetryPolicy.none`
disables retries entirely.

## Storage

### The license disappears after an app update
Expected on iOS if you use `FileLicenseStore` — the container is replaced on
reinstall, though not on a normal update.
**Fix:** `KeychainLicenseStore` survives reinstall. Read
[the trade-off](storage.md#the-reinstall-trade-off) first.

### A deleted-and-reinstalled app still has the old license
That is the Keychain working as designed.
**Fix:** expected. Give support a way to clear it, and consider whether
`FileLicenseStore` matches your intent better.

### Keychain saves fail with `errSecMissingEntitlement`
Missing keychain-sharing entitlement, or an `accessGroup` that does not match your
provisioning profile.
**Fix:** add the entitlement, or drop `accessGroup` if you are not sharing.

### Keychain reads fail in a background task
`.whenUnlocked` accessibility with a locked screen.
**Fix:** `.afterFirstUnlock`, which is the default for this reason.

### Records vanish after a crash
Should not happen — writes are atomic.
**Fix:** if it does, check the store is not being constructed with a temporary or
container-relative URL that moves between launches.

### Two managers disagree about the license
They are backed by different stores, or one has not called `start()`.
**Fix:** share one store instance. `LicenseManager` caches state after `start()`;
call `revalidate()` to re-run rules against the current record.

## CSV

### The first column cannot be found
A UTF-8 BOM is attached to the first header name — every spreadsheet on Windows
emits one.
**Fix:** the parser strips it. If you are parsing yourself, do the same.

### Rows are merged into one
CRLF terminators are not being recognised. Note that Swift treats `"\r\n"` as a
*single* `Character`, so a `Character`-based scanner matching `"\r"` or `"\n"`
silently misses it and parses the whole file as one row.
**Fix:** `CSVDocument` scans Unicode scalars for this reason. If you wrote your
own parser, this is very likely your bug.

### A customer name splits into two columns
`"Acme, Inc."` split on the comma.
**Fix:** `CSVDocument` handles quoted fields. Naive comma splitting cannot.

### "line N: '...' is not a recognised date"
A non-ISO format — `31/06/2027`, or Excel's serial numbers.
**Fix:** export as ISO-8601 (`2027-06-30`), or pre-convert. The parser accepts
`yyyy-MM-dd` and full ISO-8601 timestamps.

### Re-importing a table creates duplicate licenses
You are generating IDs instead of deriving them.
**Fix:** leave `license_id` blank and the decoder derives `csv:<normalised key>`,
which is stable across imports. Setting a random ID per import creates duplicates.

## Build and concurrency

### "sending 'X' risks causing data races"
A non-`Sendable` Foundation type is crossing an isolation boundary — commonly
`UserDefaults` or `FileManager`.
**Fix:** store an identifier (a suite name, a URL) and resolve the instance on
demand, as `UserDefaultsTimeAnchor` and `FileLicenseStore` do. Prefer that over
`@unchecked Sendable`.

### `LicenseKitVendor` will not compile into my app
It should not. It holds the private signing key type.
**Fix:** remove it from app targets. If you need trial self-issuance, see
[recipes.md](recipes.md#a-self-issued-trial) — and use a separate trial key.

### `await` required on every call
`LicenseManager` is an actor, because licensing state is genuinely shared mutable
state.
**Fix:** mirror the state into a `@MainActor @Observable` model via
`stateUpdates()` and read that synchronously from views. See
[recipes.md](recipes.md#feature-gating-patterns).

## Diagnosing anything else

```swift
print(report.debugDescription)
```

Rule by rule, with no license key and no PII:

```
ValidationReport(license-0001) @ 2027-01-15T08:00:00Z
  ✓ signature
  ✓ product
  – clockTamper (not applicable)
  ✗ validityWindow: The license expired on 2027-01-01T00:00:00Z.
  ✓ revocation
```

Note `–` versus `✓`: "not applicable" means the check did not run, which is
usually the answer when a rule "never fires".

Then turn on logging:

```swift
log: CallbackLicenseLog(minimumLevel: .debug) { level, message in
    print("[licensekit \(level)] \(message)")
}
```

The SDK never writes to a log by itself, and only ever passes redacted strings.

And compare the signed bytes:

```sh
licensekit canonical --in the.license
```

## Still stuck

Include in a report: the `debugDescription` output, the LicenseKit version, the
platform, and whether the license was issued by the CLI or your own code. Never
paste a real license key or private key.
