# The licensing model

How to express real pricing in `License` values — and which mistakes are expensive
to undo once licenses are in the wild.

## The shape

```swift
License
├─ id            LicenseID          durable primary key
├─ key           LicenseKey         the customer-facing string
├─ product       ProductReference   what it unlocks
├─ subject       LicenseSubject     who holds it
├─ policy        LicensePolicy      whether and how it may be used
├─ entitlements  EntitlementSet     what capabilities it grants
├─ issuance      IssuanceInfo       who issued it and when
└─ metadata      LicenseMetadata    anything else
```

The division between `policy` and `entitlements` is the important one. *Policy*
governs whether the license works at all. *Entitlements* govern what works. Keeping
them apart is what lets you change one without touching the other.

## Identity: three different strings

New users routinely conflate these. They answer different questions.

| Type | Question | Changes when |
|---|---|---|
| `LicenseID` | Which record is this? | Never. It is the storage primary key. |
| `LicenseKey` | What does the customer type? | You reissue a key after a support incident. |
| `ProductID` | What does it unlock? | Never, for a given product. |

Reissuing a key while keeping the ID means a customer's record updates in place
rather than accumulating duplicates. That only works if you keep them distinct.

### License keys normalise themselves

```swift
LicenseKey("abcd-efgh") == LicenseKey("ABCDEFGH")   // true
```

Comparison and hashing use a folded form with whitespace, `-`, `_`, and `.`
removed and letters upper-cased. `rawValue` preserves the original for display.

The signature covers the **normalised** form, so reformatting a key for a nicer UI
cannot break verification.

Keys are bearer credentials. Use `key.redacted` (`"****EFGH"`) anywhere a string
might be logged.

## Policy

### Kind

```swift
LicenseKind.perpetual        // never expires
LicenseKind.subscription     // valid while the upstream subscription is
LicenseKind.trial            // time-boxed evaluation
LicenseKind.complimentary    // non-commercial or comped
LicenseKind("educational")   // your own
```

An open struct, not an `enum`, for two reasons: adding a kind must not break
exhaustive `switch`es in host code, and decoding a license issued by a *newer*
version of your backend must not fail on an unrecognised value.

> **Do not gate features on `kind`.** Gate on entitlements. See
> [below](#entitlements).

### Validity window

```swift
policy.validity = ValidityWindow(notBefore: startDate, expiresAt: endDate)
policy.validity = .until(renewalDate)
policy.validity = .unbounded            // perpetual
```

Both bounds are optional. Absent `expiresAt` means it never expires.

Dates are **floored to whole seconds** on assignment. This is not cosmetic: a
signature is computed in memory but verified after a JSON round-trip, and the
interchange form carries only second precision. A license signed at `12:43:53.7`
would canonicalise one way before serialisation and another after, and would never
verify anywhere. Flooring removes the discrepancy at its source.

### Seats

```swift
policy.seats = .seats(3)
policy.seats = .unlimited
policy.seats = SeatPolicy(maxActivations: 3, transferable: true, reclaimsOldestSeat: false)
```

Seat *enforcement* needs a provider that counts activations. A local file cannot
know what other machines are doing, so `SeatLimitRule` reports itself
**not applicable** rather than guessing — see
[validation.md](validation.md#seatlimitrule).

`reclaimsOldestSeat` asks the provider to evict the oldest activation instead of
failing when the ceiling is hit. Providers that cannot do this ignore it.

Think about the customer who drops their laptop in a river. They cannot call
`deactivate()` from a device at the bottom of a river. Either allow seat
reclamation, or make sure your support team can release seats — otherwise every
lost machine becomes a permanently burned seat and a support ticket.

### Version bounds — the perpetual fallback

```swift
policy.versionBound = VersionBound(maximumVersion: "3.9.9")
```

This models "you keep the versions you paid for; upgrades need a renewal", which
is the standard arrangement for paid-upgrade desktop software.

It exists because the obvious alternative is wrong. Encoding it as an expiry date
disables software the customer legitimately owns the moment their term ends —
which is not what they bought, and generates exactly the kind of refund request
that costs more than the renewal.

`SemanticVersion` compares properly, including pre-release ordering
(`3.0.0-beta.1 < 3.0.0`). The running version comes from
`CFBundleShortVersionString` by default, and is `nil` outside an app bundle, which
correctly makes the rule inapplicable rather than enforcing against a guess.

### Grace intervals

Two independent windows, answering different questions. Confusing them is a
common and user-hostile mistake.

```swift
policy.expiryGraceInterval  = .licenseDays(3)    // keeps working PAST EXPIRY
policy.offlineGraceInterval = .licenseDays(30)   // keeps working WITHOUT A SERVER
```

**`expiryGraceInterval`** absorbs payment friction. A card declines on a Friday
evening; the retry succeeds Monday. Without grace, your customer loses a working
weekend and you get a support ticket that costs more than the invoice. With three
days of grace, nobody notices.

While inside this window the license is **valid**, and the report carries
`.withinExpiryGrace`. Show a banner; do not block.

**`offlineGraceInterval`** bounds staleness. Revocation only protects you if
devices actually check in, and this is what caps how long a cached "valid" answer
survives. Set it and a customer on a two-week flight keeps working; leave it `nil`
and offline use is unlimited — which is the right default for signed offline
licenses that have no provider to check with in the first place.

Rough guidance:

| Product | offlineGrace | Why |
|---|---|---|
| Signed offline license, no server | `nil` | Nothing to check against. |
| Subscription, consumer | 14–30 days | Covers travel and outages. |
| Subscription, enterprise | 30–90 days | Air-gapped and locked-down fleets exist. |
| High-value seat-limited | 7–14 days | Tighter revocation, at a UX cost. |

Below one day is almost always wrong: it turns a hotel Wi-Fi captive portal into a
lockout.

## Entitlements

```swift
license.entitlements = [
    Entitlement(id: "export.pdf"),
    Entitlement(id: "sync.cloud", limit: 3),
    Entitlement(id: "api.access", attributes: ["tier": "gold"]),
]
```

```swift
if await licensing.isEntitled(to: "export.pdf") { … }
let devices = await licensing.limit(for: "sync.cloud") ?? 1
```

### Why not gate on the license kind

Because tiers are a sales artefact and capabilities are a code artefact, and they
change on different schedules.

```swift
// Don't. Every pricing change is now a code change, and every new tier
// means auditing every call site to see which side of the line it falls on.
if license.policy.kind == .subscription && tier == "pro" { enableExport() }

// Do. Pricing moves; this does not.
if await licensing.isEntitled(to: "export.pdf") { enableExport() }
```

When marketing splits "Pro" into "Pro" and "Studio" next year, the second version
needs no code change at all — only different entitlement sets on newly issued
licenses.

### Naming

Dotted, hierarchical, and named after the capability rather than the tier:

```
export.pdf          export.svg          sync.cloud
collaboration.live  api.access          support.priority
```

Not `pro`, `tier2`, or `paid_features`. Those names encode a pricing decision you
will change.

Entitlement IDs are permanent once issued — a license granting `export.pdf` cannot
be retroactively edited to say something else. Renaming means either reissuing
every license or carrying an alias in code forever. Spend a few minutes on the
names.

### Limits

`limit` expresses a numeric ceiling attached to a capability — connected devices,
projects, team members. It is *not* a usage meter; LicenseKit does not count
consumption. If you need "500 API calls per month", track that yourself and use
the limit as the configured ceiling.

## Subject

```swift
LicenseSubject(
    customerID: "cus_123",
    name: "Jane Smith",
    email: "jane@example.com",
    organization: "Acme, Inc."
)
```

Every field is optional, because providers differ wildly in what they disclose —
some return a full customer record, others only an opaque ID. A domain that
*required* an email would be unimplementable against half of them.

**This is personal data.** It is deliberately excluded from
`License.redactedDescription`, and `subject.redactedDescription` masks the local
part of the email. Never log the raw values, and remember that a license file
containing a customer's name and address is a GDPR-relevant artefact when it lands
in your support inbox.

## Metadata

```swift
license.metadata["campaign"] = .string("black-friday-2026")
license.metadata["seatBlock"] = .integer(50)
```

`MetadataValue` is a closed enum of JSON scalars, not `[String: Any]`. An untyped
bag would be neither `Sendable` nor `Codable`, and — the reason that actually
matters — could not be canonically serialised, which would make it impossible to
include metadata under the signature.

Metadata **is signed**. Use it for facts fixed at issuance (campaign, purchase
order, reseller). For anything a provider can change after issuance — status,
current seat count, renewal date — use `LicenseRecord.providerState`, which lives
outside the signature.

## `License` vs `LicenseRecord`

The split that makes the rest work.

```swift
LicenseRecord
├─ license          License                 ← signed, immutable
├─ signature        LicenseSignature?
├─ origin           LicenseOrigin           which provider, which medium, when
├─ activation       ActivationInfo?         this machine's seat
├─ providerState    ProviderStateSnapshot   status, expiry override, seat count
└─ lastValidatedAt  Date?                   drives offline grace
```

Only `license` is signed. Everything else is local, mutable, and unsigned. Three
consequences:

1. **A renewal never requires reissuing.** The provider moves
   `providerState.expiresAt` forward; the signature is untouched.
2. **Local tampering can only remove privileges.** The signed claim set is the
   upper bound on what a holder can be granted, so editing the record cannot
   manufacture an entitlement.
3. **Revocation is expressible** without the contradiction of a license that is
   validly signed but must not be honoured.

### Which expiry wins

```swift
record.effectiveExpiry    // providerState.expiresAt ?? license.policy.validity.expiresAt
```

The provider's assertion supersedes the signed policy, because only the provider
knows what happened *after* issuance. A subscription signed with a March expiry
that renewed in February reports April, with no reissue.

## Worked examples

### Paid-upgrade desktop app

```swift
LicenseSpecification.perpetual(
    product: ProductReference(id: "com.example.studio", name: "Studio"),
    issuer: "com.example.licensing",
    subject: LicenseSubject(name: order.name, email: order.email),
    entitlements: [Entitlement(id: "export.pdf"), Entitlement(id: "batch.render")],
    seats: 2,
    maximumVersion: "3.9.9"      // 4.0 needs an upgrade purchase
)
```

Never expires, works forever offline, and 4.0 politely asks for money.

### Consumer subscription

```swift
LicenseSpecification.subscription(
    product: ProductReference(id: "com.example.app"),
    issuer: "com.example.licensing",
    expiresAt: renewalDate,
    entitlements: [Entitlement(id: "sync.cloud", limit: 5)],
    seats: 5,
    offlineGrace: .licenseDays(30),
    expiryGrace: .licenseDays(3)
)
```

Thirty days on a plane is fine; three days of a failing card is invisible.

### Time-boxed trial

```swift
LicenseSpecification.trial(
    product: ProductReference(id: "com.example.app"),
    issuer: "com.example.licensing",
    expiresAt: Date().addingTimeInterval(.licenseDays(14)),
    entitlements: [Entitlement(id: "export.pdf")]
)
```

One machine, non-transferable. Pair with a persisted `MonotonicTimeAnchor` so
winding the clock back does not restart it — see
[recipes.md](recipes.md#a-self-issued-trial).

### Enterprise site license

```swift
var policy = LicensePolicy(kind: LicenseKind("site"))
policy.seats = .seats(500)
policy.validity = .until(contractEnd)
policy.offlineGraceInterval = .licenseDays(90)   // air-gapped fleets exist

LicenseSpecification(
    product: ProductReference(id: "com.example.studio"),
    issuer: "com.example.licensing",
    subject: LicenseSubject(organization: "Acme, Inc."),
    policy: policy,
    entitlements: [Entitlement(id: "export.pdf"), Entitlement(id: "sso")],
    metadata: ["purchaseOrder": .string("PO-99213")]
)
```

Distributed as one file through MDM. See
[recipes.md](recipes.md#a-site-license-distributed-by-mdm).

## What is expensive to change later

Issued licenses are immutable and live in customers' hands for years. These are the
decisions to get right the first time:

| Decision | Why it is hard to undo |
|---|---|
| Entitlement IDs | Baked into signed licenses. Renaming means reissuing or aliasing forever. |
| `ProductID` | Changing it invalidates every existing license against `ProductRule`. |
| Signing key | Rotatable — but only if your app trusts *several* public keys from day one. |
| `fingerprintSalt` | Changing it re-fingerprints every device, orphaning every seat. |
| Canonical form | Frozen. Adding optional fields is safe; anything else needs a version bump. |

Ship trusting at least two public key IDs from version 1, even if the second key
does not exist yet. Rotation without it means an app update *and* reissuing every
outstanding license simultaneously.

## Next

- [Validation](validation.md) — how each of these fields is enforced
- [Issuing](issuing.md) — turning specifications into signed files
- [Recipes](recipes.md) — complete worked implementations
