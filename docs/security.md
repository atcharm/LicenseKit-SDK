# Security

What LicenseKit defends against, what it does not, and how to hold it correctly.

The short version: **the signature is the only trust anchor.** Everything else —
encryption, storage, machine binding, clock checks — raises the cost of misuse
without being load-bearing. Design your product on that basis and you will not be
surprised.

## Threat model

| Threat | Defence | Effective? |
|---|---|---|
| Editing a license file to extend it or add features | Ed25519 signature over a canonical byte form | **Yes.** Computationally infeasible without your private key. |
| Forging a license from scratch | Same | **Yes.** |
| Sharing one license across many machines | Machine binding + seat accounting | **Yes**, when a provider counts seats. Not detectable offline. |
| Using a refunded or revoked license | Provider revocation + bounded offline grace | **Yes**, within the grace window. |
| Rolling the clock back to defeat expiry | Monotonic time anchor | **Partly.** Raises cost; defeatable by clearing local state. |
| Reading a license file's contents | Optional sealing | **In transit and at rest only.** Not against the device owner. |
| Editing the local record store | Signature bounds the claim set | **Yes.** Tampering can only remove privileges. |
| Replaying an old license after a downgrade | Version bounds, provider expiry | Partly — depends on your policy. |
| **Patching the binary to skip the check** | **None** | **No. Nothing here helps.** |

That last row is the one to internalise.

## The limit worth being honest about

No client-side licensing SDK can defend against someone modifying your compiled
application. Your check is `if entitled { … }`; an attacker flips the branch. This
is not a LicenseKit weakness — it is true of every client-side licensing system
ever shipped, including the expensive ones.

LicenseKit's goal is therefore stated narrowly: **make honest use easy and casual
copying ineffective.** Sending a friend your license file should not work. Editing
an expiry date in a text editor should not work. Both of those hold.

Keeping that boundary explicit matters practically, not just philosophically. The
alternative is a slow accumulation of obfuscation, integrity self-checks, and
anti-debugging that costs real users reliability, costs you support time, and
buys a delay measured in hours against anyone actually motivated. If piracy is an
existential risk for your product, the answer is server-side execution of the
valuable part, not a cleverer client check.

## Key handling

### The rules

1. **Never ship the private key.** Not in the bundle, not in `Info.plist`, not in
   an obfuscated constant, not in a CI artefact that ends up in the app.
2. **Public keys are safe everywhere.** In the binary, in a public repo, on your
   website. A public key discloses nothing and forges nothing.
3. **Back up the private key.** Losing it means never issuing another license that
   already-shipped apps accept. There is no recovery.
4. **Trust two key IDs from version 1**, even if the second key does not exist
   yet. Rotation without it needs an app update *and* a full reissue at the same
   moment.

### Verifying you got it right

```sh
# Should print 0.
strings YourApp.app/Contents/MacOS/YourApp | grep -c "$(cat keys/vendor-2026.private)"

# Which targets pull in the vendor module? Should be none of your app targets.
swift package show-dependencies
grep -rn "LicenseKitVendor" --include="*.swift" Sources/YourApp/
```

Add the first one to CI. It is two lines and it catches the single most expensive
mistake available.

### Where the private key should live

| Context | Storage |
|---|---|
| Issuing service | Secrets manager, injected at boot |
| CI (release signing) | Encrypted CI secret, never echoed |
| One developer, small product | Encrypted offline backup + password manager |
| High value | HSM with P-256, using `.ecdsaP256` |

Do not bake it into a container image. That puts it in your registry, your build
logs, and every laptop that has pulled the image.

## Sealing is not authentication

Stated once more because it is the most common misconception.

Encryption of a license container gives you:

- confidentiality in transit and at rest,
- tamper-evidence — a modified byte fails to decrypt rather than mis-parsing.

It does **not** give you authenticity against the device owner, because your app
must carry the symmetric key to open the file, and anything in a shipped binary
can be extracted.

LicenseKit therefore always **signs first, seals second**. Authenticity rests on a
key that never leaves your control and survives the sealing key leaking — which,
given enough customers and enough time, it will.

**Shipping unsealed signed licenses is a legitimate and often better choice.** You
lose nothing security-relevant and gain support tickets you can actually read.
Reach for sealing when license contents are commercially sensitive — customer
names, contract terms in metadata — not because encryption sounds safer.

## Personal data

License subjects carry names, email addresses, and organisations. That has
consequences beyond security:

- **Records on disk contain PII.** `FileLicenseStore` writes plain JSON. Mention it
  in your privacy policy, and be able to delete it on request.
- **License files sent by email contain PII**, and land in your support inbox and
  the customer's mail provider.
- **Fingerprints are salted hashes, not identifiers.** A per-product salt is what
  stops the value you store being correlatable with what another vendor stores for
  the same machine. Use a distinct salt per product; it need not be secret.
- **Changing the salt orphans every seat**, because every device re-fingerprints.
  Choose one and keep it.

### Redaction

The SDK never writes to a log itself — where licensing activity goes is your
decision, not the SDK's. When you do log:

```swift
key.redacted                    // "****EFGH"
license.redactedDescription     // no key, no PII
subject.redactedDescription     // "customer=cus_1 email=***@example.com"
report.debugDescription         // rule-by-rule, contains neither
```

```swift
// Don't — a bearer credential and a customer's identity, in your crash reporter.
log("activating \(license.key) for \(license.subject.email ?? "")")

// Do.
log("activating \(license.redactedDescription)")
```

Be careful with third-party crash and analytics SDKs, which frequently capture
breadcrumbs automatically.

## Cryptographic choices

| Choice | What | Why |
|---|---|---|
| Signature | Ed25519 (default), ECDSA P-256 | Small, no parameter choices to get wrong, constant-time by construction. P-256 for HSM compatibility. |
| Sealing | ChaCha20-Poly1305 (default), AES-256-GCM | ChaCha is constant-time in software everywhere, including older watchOS and tvOS hardware without AES acceleration. |
| Hashing | SHA-256, salted with a separator byte | The separator makes `("ab","c")` and `("a","bc")` hash differently. |
| Key derivation | HKDF-SHA256 | For build-time secrets only — **not** a password hash, and no brute-force resistance for low-entropy input. |

Implementation notes that matter to a reviewer:

- **Algorithm confusion is blocked.** A key is bound to one algorithm at
  registration, and a signature claiming a different one is rejected rather than
  dispatched on. Honouring the signature's own claim would let an attacker choose
  the verification path.
- **Domain separation.** The canonical form carries a `$type` tag, so bytes
  produced for another structure cannot be replayed as a license signature.
- **Unsealing failures are uniform.** A wrong key, a corrupted byte, and a tampered
  header are indistinguishable to the caller, so nothing helps an attacker
  distinguish them either.
- **Failing closed is the default.** No configured keys means `RejectingVerifier`,
  which accepts nothing. A signature present with no verifier is a *failure*, not
  a pass. A rule that throws is recorded as a failure. Every ambiguous path denies.

## Clock tampering

```swift
timeAnchor: UserDefaultsTimeAnchor()        // survives relaunch
```

The SDK records the furthest-forward instant it has ever seen and treats a large
backwards jump as tampering, with a one-day default tolerance.

The tolerance is deliberate. NTP corrections, dead coin cells, and mishandled
date-line crossings all move clocks backwards legitimately. Punishing a user whose
clock is merely wrong costs more than the trial extension it prevents.

It is defeatable by clearing the app's `UserDefaults`. That is an accepted trade:
it moves the attack from "change the date in Settings" — which anyone can do — to
"find and reset the SDK's persisted state", which is enough for a trial.

For a hard guarantee, the only real answer is a server timestamp, which means
requiring connectivity.

## Pre-launch checklist

- [ ] No private signing key in any shipped artefact (`strings` check in CI).
- [ ] `LicenseKitVendor` is not a dependency of any app target.
- [ ] Private key backed up in at least two places, tested by restoring it.
- [ ] App trusts **two** key IDs, so rotation is possible later.
- [ ] Key rotation procedure written down, not just understood.
- [ ] No license key or PII in logs, breadcrumbs, or crash reports.
- [ ] `offlineGraceInterval` set deliberately, and you can state why.
- [ ] Revoking a license upstream demonstrably locks an app within that window.
- [ ] Tampered license file → clean rejection, no crash.
- [ ] Wrong-key license → rejection.
- [ ] Wrong-product license → rejection.
- [ ] Expired license → renewal path, not a dead end.
- [ ] Support can release a seat for a customer whose device is gone.
- [ ] Privacy policy covers licensing data.
- [ ] You have a plan for a leaked private key, written before you need it.

## Reporting a vulnerability

Report security issues privately to the maintainer rather than opening a public
issue. Include a reproduction and the version.

## Next

- [Issuing](issuing.md) — key generation and rotation mechanics
- [Architecture §6](architecture.md#6-trust-model) — the same model, from the design side
- [Validation](validation.md) — which rule enforces what
