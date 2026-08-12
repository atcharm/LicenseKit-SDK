# Architecture

Read this before modifying LicenseKit itself, or when you need to know *why*
something is shaped the way it is. The API reference lives in the source; this is
the reasoning behind it.

If you are building an app rather than modifying the SDK, you probably want
[getting-started.md](getting-started.md) instead.

---

## 1. The central idea

A licensing SDK fails in one of two ways. Either the core acquires knowledge of
specific vendors — a `if provider == .gumroad` here, a Paddle-shaped field
there — until adding a provider means touching validation, storage, and models
alike. Or the abstraction is so thin that every integration reimplements retry,
error mapping, and grace-period policy, and each one gets it subtly wrong.

LicenseKit avoids both by drawing exactly one line:

> **The core domain describes what a license *is*. It has no opinion about
> where a license came from.**

Everything vendor-specific enters through one of five protocol seams. Nothing
crosses inward. `LicenseKitCore` compiles with no networking, no cryptography,
and no persistence — which is not an aesthetic preference but the mechanism that
keeps the rule enforceable. A vendor detail *cannot* leak into the core, because
the core cannot express it.

---

## 2. Layering

Dependencies point strictly downward. Any arrow the other way is a bug.

```
┌───────────────────────────────────────────────────────────┐
│  LicenseKit          composition root + LicenseManager    │
└───────────────────────────────────────────────────────────┘
        │              │              │              │
        ▼              ▼              ▼              ▼
┌──────────────┐┌─────────────┐┌────────────┐┌───────────────┐
│  ...Crypto   ││  ...Formats ││ ...Storage ││  ...Providers │
│ sign / seal  ││ JSON / CSV  ││ file / kc  ││  HTTP adapters│
└──────────────┘└─────────────┘└────────────┘└───────────────┘
        │              │              │              │
        └──────────────┴──────┬───────┴──────────────┘
                              ▼
              ┌───────────────────────────────┐
              │        LicenseKitCore         │
              │  models · protocols · rules   │
              │  canonical form · errors      │
              │      (no platform deps)       │
              └───────────────────────────────┘

              ┌───────────────────────────────┐
              │      LicenseKitVendor         │  ← never link into a client
              │  issuing · signing · sealing  │
              └───────────────────────────────┘
```

The sibling capability modules do not know about each other. `LicenseKitFormats`
performs no cryptography; it accepts an injected `LicenseUnsealing`.
`LicenseKitProviders` performs no persistence. Only the top layer composes them,
and it is the only place that knows the stack exists.

`LicenseKitVendor` is a separate target so that shipping a private signing key
inside a client application requires a deliberate act, not an accidental import.

---

## 3. The five seams

Every extension point in the SDK is one of these. There are deliberately no
others — a sixth would mean the boundary was drawn wrong.

| Seam | Protocol | Answers |
|---|---|---|
| **Source** | `LicenseSource` | "What licenses exist?" (tables, manifests) |
| **Provider** | `LicenseProvider` | "Is this key valid, and may this device use it?" |
| **Store** | `LicenseStore` | "What was installed last time?" |
| **Codec** | `LicenseEnvelope`, `JSONLicenseCodec` | "How is a license represented?" |
| **Crypto** | `LicenseSigning` / `Verifying` / `Sealing` | "Did the vendor authorise this?" |

Supporting seams — `LicenseClock`, `HTTPTransport`, `MachineIdentityProviding`,
`LicenseLogging`, `LicenseRule` — exist for the same reason: everything the SDK
depends on that is environmental, non-deterministic, or a matter of host policy
is injected rather than reached for.

### Why `LicenseSource` and `LicenseProvider` are separate

They look similar and are not. A *source* is an enumerable table with no seats,
no network, and no side effects. A *provider* is an authority you ask
permission from. Merging them would force every CSV file to implement — and
refuse — four network operations, and would make `capabilities` meaningless.

---

## 4. `License` vs `LicenseRecord`

This split is the backbone of the design.

```
License              ← immutable, vendor-signed, identical on every device
  ├─ id, key, product, subject
  ├─ policy      (kind, validity, seats, version bound, grace)
  ├─ entitlements
  └─ issuance

LicenseRecord        ← local, mutable, unsigned
  ├─ license        (the above, untouched)
  ├─ signature
  ├─ origin         (which provider, which medium, when)
  ├─ activation     (this machine's seat)
  ├─ providerState  (status, provider-asserted expiry, seat count)
  └─ lastValidatedAt
```

Only `License` is signed. Everything mutable lives outside the signature, which
produces three properties worth having:

1. **A renewal never requires reissuing.** A provider moves
   `providerState.expiresAt` forward; the signature is untouched.
2. **Local tampering can only remove privileges, never add them.** The signed
   claim set is the upper bound on what a holder is entitled to.
3. **Revocation is expressible.** A vendor can withdraw a license after
   issuance without the contradiction of "signed but not valid".

`LicenseRecord.effectiveExpiry` resolves the two sources of truth: a provider's
assertion wins, because only the provider knows what happened after issuance.

---

## 5. The canonical form

Signatures are computed over a hand-written canonical byte encoding
(`Canonical/`), never over `Codable` output.

`JSONEncoder` output is not a stable contract. Key order follows declaration
order, date handling follows encoder configuration, and adding a field with a
default value changes the bytes. Any of those invalidates every previously
issued license — silently, and only on customers' machines.

The canonical form fixes all of it:

- object keys sort by **UTF-8 byte order**, not Unicode collation (collation is
  locale- and ICU-version-dependent);
- absent values are **omitted**, not emitted as `null`, so adding an optional
  field later leaves old licenses byte-identical;
- dates are **integer milliseconds**, and every date in a signed model is
  floored to a whole second at construction;
- a `$type` tag provides **domain separation**, so bytes produced for another
  structure cannot be replayed as a license signature;
- `$canon` records the scheme version, so it can evolve without stranding
  issued licenses.

> **Why second precision matters.** A signature is computed over an in-memory
> license, but verified after a round-trip through JSON — and the interchange
> form carries only second precision. A license signed at `12:43:53.7` would
> canonicalise one way before serialisation and another way after, and would
> never verify anywhere. Flooring at construction removes the discrepancy at its
> source rather than hoping two encoders agree about rounding.

The mapping in `License+Canonical.swift` is written by hand so that extending a
model is a visible, reviewable diff rather than an accident of synthesis. That
file carries its own rules for safe change.

---

## 6. Trust model

**What the signature establishes.** An Ed25519 (or P-256) signature by a vendor
key proves the vendor authorised exactly this claim set. This is the only trust
anchor in the SDK. Everything else is defence in depth.

**What sealing does *not* establish.** Symmetric encryption provides
confidentiality in transit and at rest, and makes casual tampering fail loudly.
It provides **no authenticity against the device owner**, because a client must
carry the key in order to open the file, and anything in a shipped binary can be
extracted.

Consequently, LicenseKit always **signs first and seals second**. Authenticity
survives even if the sealing key leaks — which, given enough customers and
enough time, it will. An app that ships *unsealed* signed licenses loses nothing
security-relevant and gains debuggable support tickets.

### What this design does and does not defend against

| Threat | Defence |
|---|---|
| Forged or edited license | Signature — effective |
| Replayed license on another machine | Machine binding + seat accounting — effective when a provider does seat accounting |
| Clock rolled back to defeat expiry | Monotonic time anchor — raises cost, defeatable by clearing local state |
| Indefinite offline use of a revoked license | Bounded offline grace — effective within the configured window |
| Patched binary that skips the check entirely | **None.** No client-side SDK can defend against this |

That last row is stated plainly because a licensing SDK that implies otherwise
is selling something it cannot deliver. LicenseKit's goal is to make honest use
easy and casual copying ineffective, not to defeat a determined reverse
engineer. Keeping that boundary explicit is what stops the design from
accumulating obfuscation that costs real users reliability and buys nothing.

---

## 7. Validation as a rule chain

Validation is a list of independent `LicenseRule` values, each a pure function
of a `ValidationContext`.

The chain returns a **`ValidationReport`, not a `Bool`**. A licensing UI must
explain *why* a license was rejected in order to offer the right remedy —
"expired" wants a renewal prompt, "machineMismatch" wants a
deactivate-elsewhere flow, "signatureInvalid" wants neither. The default
strategy evaluates every rule, because knowing all three reasons a license
failed lets a UI give one good instruction instead of three sequential ones.

Rules distinguish three outcomes beyond failure:

- **satisfied with warnings** — valid, but the user should be told something
  (expiring soon, running on grace, seats exhausted);
- **not applicable** — nothing to check, recorded distinctly so a diagnostic
  report never implies a check ran when it did not.

A rule that throws is recorded as a **failure**, never a pass. One misbehaving
custom rule cannot take down a validation pass, and cannot silently open a gate.

### Grace periods

Two independent windows, because they answer different questions:

- `expiryGraceInterval` — how long past expiry the software keeps working.
  Absorbs failed payment retries. Without it, a card that declines on a Friday
  locks a paying customer out of their work.
- `offlineGraceInterval` — how long the software runs without reaching a
  provider. Bounds how stale a cached "valid" answer may be, which is what makes
  revocation meaningful.

The runtime's rule is that **only a definitive provider answer changes local
status**. A timeout, a 500, or a lost connection preserves the cached record and
lets grace decide. A 404 or an explicit rejection revokes. Conflating those is
how a flaky café network turns into a support ticket claiming the software
"deactivated itself".

---

## 8. Adding a provider

The concrete test of the architecture: adding Gumroad, Polar, or a bespoke
backend touches **no existing file**. Write one `RemoteProviderAdapter`:

```swift
struct AcmeAdapter: RemoteProviderAdapter {
    let providerID: ProviderID = "acme"
    let capabilities: ProviderCapabilities = [.activation, .remoteValidation, .refresh]

    func activationRequest(for request: ActivationRequest) throws -> HTTPRequest {
        HTTPRequest.formPost(
            url: URL(string: "https://api.acme.test/licenses/redeem")!,
            fields: ["key": request.key.rawValue, "device": request.fingerprint?.rawValue ?? ""]
        )
    }

    func decodeActivation(
        _ response: HTTPResponse, for request: ActivationRequest, at now: Date
    ) throws -> LicenseRecord {
        let json = try JSONValue(parsing: response.body)
        // ...map onto License / LicenseRecord...
    }
}
```

An adapter is **pure translation**. It performs no I/O, no retries, and makes no
policy decisions — `RemoteLicenseProvider` owns all of that, once, for every
adapter. So an adapter has no asynchronous code and no networking dependency,
can be tested exhaustively against recorded response bodies, and a bug in retry
logic gets fixed once rather than once per integration.

Only implement the operations your `capabilities` advertise; every other method
defaults to reporting itself unsupported. Adding a new operation to the protocol
later therefore cannot break existing adapters.

Compare `GumroadAdapter` and `PolarAdapter` in `Sources/LicenseKitProviders/Adapters/`
for the clearest illustration: two services with different data models,
different activation semantics, and different error conventions, reduced to the
same domain types without either leaking into the core.

Full guide, including error mapping and testing: **[providers.md](providers.md)**.

### Decoding defensively

Adapters deliberately avoid `Codable` structs for provider responses. Licensing
APIs change shape without warning, return `null` where they documented a string,
and encode booleans as `"true"`. A `Codable` struct turns any of those into a
total decode failure — which locks a paying customer out over a field the SDK
never needed. `JSONValue` degrades instead: unknown fields are ignored, missing
optional ones stay `nil`.

---

## 9. Concurrency

The package builds under **Swift 6 language mode with strict concurrency**, and
every public type is `Sendable`.

`LicenseManager` is an `actor` because licensing state is genuinely shared
mutable state — a settings panel, a feature gate, and a background refresh can
all touch it at once. Serialising through an actor eliminates that class of bug
rather than documenting a locking discipline nobody will follow.

Where a Foundation type is thread-safe but not `Sendable` (`UserDefaults`,
`FileManager`), the SDK stores an identifier and resolves the instance on demand
rather than reaching for `@unchecked Sendable`. There is exactly one
`@unchecked Sendable` in the package, in the CLI's async-to-sync bridge, with
the happens-before argument written out at the declaration.

---

## 10. Testability

Every non-deterministic input is injected: time (`LicenseClock`), device
identity (`MachineIdentityProviding`), networking (`HTTPTransport`), persistence
(`LicenseStore`). Consequently the entire 146-test suite runs in ~30ms with no
network, no filesystem dependency beyond a handful of temp files, and no
wall-clock sensitivity.

`LicenseKitConfiguration` is the single composition root. A test builds one with
fakes and gets a fully deterministic `LicenseManager`; production builds one with
real implementations. There is no third path — which is what keeps the two
honest about each other.

---

## 11. Lifecycles

What actually happens, in order. Useful when debugging, and when deciding where a
change belongs.

### `start()`

```
store.mostRecentlyValidated()
  └─ nil ──────────────────────────────────► publish(.unlicensed)
  └─ record
       ├─ evaluate(record, connectivity: .notConsulted)
       │    ├─ timeAnchor.highWaterMark()      read BEFORE advancing
       │    ├─ timeAnchor.advance(to: now)
       │    ├─ machineIdentity.fingerprint()   cached for the process
       │    └─ validator.validate(context) ──► publish(.licensed | .invalid)
       └─ if refreshesOnStart && shouldRefresh ─► refreshQuietly()
```

Two details that are easy to get wrong if you touch this:

**The time anchor is read before it is advanced.** Advancing first would compare
now against itself, and a clock set backwards would get one free pass on every
launch.

**`start()` never throws.** A corrupt store publishes `.unlicensed`; it does not
propagate. A launch path must produce some state.

### `activate(key:)`

```
resolveProvider(providerID, for: .activate)
  └─ provider.activate(request)              network, retries, error mapping
       ├─ throws ─────────────────────────►  LicenseKitError.provider
       └─ record
            ├─ evaluate(record, connectivity: .online)
            ├─ not .licensed ──────────────►  throw; record is NOT persisted
            └─ .licensed ──────────────────►  store.save(record)
```

The non-persistence on failure is deliberate. Storing a license the app rejects on
every launch produces a permanently broken install with no obvious way out.

### `refresh()`

The decision that matters most in the whole runtime:

```
provider.refresh(record)
  ├─ success ────────────────► persist, evaluate(connectivity: .online)
  ├─ transient failure ──────► KEEP cached record,
  │  (unreachable, timeout,    evaluate(connectivity: .offline)
  │   5xx, rate limited)       └─ offline grace decides
  └─ definitive failure ─────► applyDefinitiveFailure → .revoked,
     (404, rejected,           persist, evaluate, THEN throw
      seat limit)
```

A transient failure does **not** throw. The customer's network is not the
customer's fault, and an exception here would push every caller into writing the
same "was it just the network?" branch — which is precisely the logic that gets
written differently, and wrongly, in each place.

### `deactivate()`

```
provider.deactivate(record)      best-effort; capture any error
store.remove(record.id)          ALWAYS
publish(.unlicensed)             ALWAYS
throw captured error             if there was one
```

The local record goes even if the provider call fails. A user who asked to sign
out must end up signed out. A stranded remote seat is recoverable through your
dashboard; an app that refuses to forget a license is not.

---

## 12. Source map

Where to look when changing something.

```
Sources/
├── LicenseKitCore/
│   ├── Model/            License, LicenseRecord, policy, entitlements,
│   │                     identifiers, signature, state
│   ├── Canonical/        CanonicalValue, CanonicalEncoder,
│   │                     License+Canonical  ← the frozen signing contract
│   ├── Validation/       LicenseRule, LicenseValidator, BuiltinRules,
│   │                     ValidationContext, ValidationReport
│   ├── Protocols/        the five seams + clock, transport, logging
│   └── Support/          errors, SemanticVersion, clock, time anchor
│
├── LicenseKitCrypto/     KeyMaterial, Signing, Sealing, Fingerprinting
├── LicenseKitFormats/    LicenseEnvelope, JSONLicenseCodec, CSVParser,
│                         CSVLicenseSource, LicenseFileReader
├── LicenseKitStorage/    FileLicenseStore, KeychainLicenseStore
├── LicenseKitProviders/  URLSessionTransport, RemoteProviderAdapter,
│                         RemoteLicenseProvider, JSONValue,
│                         OfflineLicenseProvider, Adapters/
├── LicenseKit/           LicenseManager, LicenseKitConfiguration,
│                         MachineIdentity
└── LicenseKitVendor/     LicenseIssuer, LicenseSpecification, CSVLicenseImport
```

### Where a change belongs

| Changing | Goes in |
|---|---|
| A new license field | `Core/Model/` **and** `Core/Canonical/License+Canonical.swift` |
| A new validation check | `Core/Validation/BuiltinRules.swift`, or your own `LicenseRule` |
| A new provider | `LicenseKitProviders/Adapters/` — nothing else |
| A new storage backend | Conform to `LicenseStore` anywhere |
| A new signature algorithm | `Crypto/Signing.swift` + a `SignatureAlgorithm` constant |
| Anything provider-specific | **Never** in `LicenseKitCore` |

### The one file to be careful with

`Core/Canonical/License+Canonical.swift` defines the bytes every signature covers,
for the lifetime of every license ever issued. It carries its own rules at the
top. In short:

- **Adding an optional field is safe** — absent values are omitted, so already-issued
  licenses keep the same bytes.
- **Renaming a key or changing a representation is breaking** — it needs a
  `CanonicalEncoder.currentVersion` bump with the old encoder kept reachable.
- **Never include locally-mutable state.** Only `License` is signed.

A mistake here does not fail in CI. It fails months later, on customers'
machines, for licenses you can no longer change.
