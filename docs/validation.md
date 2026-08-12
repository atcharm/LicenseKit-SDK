# Validation

Validation is a list of independent rules, each a pure function of a context. It
returns a report, not a boolean.

## Why a report

A licensing screen has to explain itself. "Expired" wants a renewal button;
"machineMismatch" wants a deactivate-elsewhere flow; "signatureInvalid" wants
neither — it wants "contact support", because the honest reading is that someone
handed your customer a forged file.

```swift
let report = await validator.validate(context)

report.isValid            // Bool, if that is genuinely all you need
report.failures           // [ValidationFailureReason] — every reason, not just the first
report.warnings           // [ValidationWarning] — valid, but tell the user
report.summary            // one user-facing sentence
report.isRunningOnGrace   // valid only because a grace window is covering it
report.debugDescription   // multi-line rule-by-rule trace, no PII
```

The default strategy evaluates **every** rule. A license that is expired, for the
wrong product, *and* unsigned should tell you all three at once — otherwise your
user fixes one problem, retries, and discovers the next one. One good instruction
beats three sequential ones.

```swift
var validator = LicenseValidator.offlineDefault()
validator.strategy = .stopAtFirstFailure    // only when the verdict is all you use
```

## Running one

Normally you do not. `LicenseManager` builds the context and runs the chain for
you, on `start()`, `install()`, `activate()`, `refresh()`, and `revalidate()`.

Directly, for tests or a custom flow:

```swift
let context = ValidationContext(
    record: record,
    now: Date(),
    expectedProduct: "com.example.app",
    applicationVersion: SemanticVersion.fromMainBundle(),
    machineFingerprint: fingerprint,
    verifier: verifier,
    connectivity: .notConsulted,
    timeAnchor: previousHighWaterMark
)

let report = await LicenseValidator.offlineDefault().validate(context)
```

Rules read only from the context — never from ambient state — which is what makes
them reorderable, individually testable, and free of hidden coupling.

## The default chains

```swift
LicenseValidator.offlineDefault()    // signed license files, no server
LicenseValidator.connectedDefault()  // a provider is involved
```

| Rule | offlineDefault | connectedDefault |
|---|---|---|
| `SignatureRule` | `.required` | `.requiredWhenPresent` |
| `ProductRule` | ✓ | ✓ |
| `ClockTamperRule` | ✓ | ✓ |
| `ValidityWindowRule` | ✓ | ✓ |
| `RevocationRule` | ✓ | ✓ |
| `VersionBoundRule` | ✓ | ✓ |
| `MachineBindingRule` | ✓ | ✓ |
| `SeatLimitRule` | — | ✓ |
| `OfflineGraceRule` | — | ✓ |

The signature policy differs because the trust story differs. An offline file is
trustworthy *only* because it is signed, so an unsigned one is meaningless. A
license fetched from an authenticated API over TLS already has an authenticity
story, so an unsigned response is tolerated with a warning rather than rejected.

Signature verification is ordered first so that a forged license is rejected *for
forgery*, rather than for whatever the forger happened to get wrong.

## The rules

### `SignatureRule`

The one that matters. Every other check is decoration if the claim set can be
edited with a text editor.

```swift
SignatureRule(policy: .required)            // reject anything unsigned
SignatureRule(policy: .requiredWhenPresent) // verify if present, warn if not
SignatureRule(policy: .disabled)            // tests and previews only
```

Fails with `.signatureMissing`, `.signatureInvalid`,
`.unknownSigningKey(KeyIdentifier)`, or `.unsupportedAlgorithm`.

Those are distinct on purpose. `.unknownSigningKey` means a rotation or
configuration problem — your app does not trust the key that signed this. `.signatureInvalid`
means the bytes do not match. The first is your bug; the second is not.

Under `.required`, a signature present with **no configured verifier** is a
*failure*, not a pass. Forgetting to configure keys must never become a silent
bypass.

### `ProductRule`

Rejects a license issued for a different product. Without it, a valid license for
the cheapest thing in your catalogue unlocks the most expensive one.

Inapplicable when `expectedProduct` is `nil`.

### `ValidityWindowRule`

Enforces `notBefore` and `expiresAt`, reading `record.effectiveExpiry` so a
provider-asserted renewal supersedes the signed date.

```swift
ValidityWindowRule(warningThreshold: .licenseDays(14))
```

- Before `notBefore` → `.notYetValid(startsAt:)`
- Past expiry, no grace → `.expired(at:)`
- Past expiry, inside `expiryGraceInterval` → **valid**, warns `.withinExpiryGrace`
- Within `warningThreshold` of expiry → valid, warns `.expiringSoon`

### `RevocationRule`

Reads `providerState.status`:

| Status | Result |
|---|---|
| `.active` | passes |
| `.revoked` | `.revoked` — refunded, charged back, withdrawn |
| `.lapsed` | `.expired` — subscription ended, account still exists |
| `.unknown` while offline | passes, warns `.providerUnreachable` |

### `MachineBindingRule`

Confirms the record's activation belongs to this machine. Fails with
`.machineMismatch` when a record is copied to another device.

Inapplicable when there is no activation on record — an unbound license (a site
license, or a source that does not do seats) is a legitimate configuration, not a
violation.

### `SeatLimitRule`

Compares `providerState.activationCount` against `policy.seats.maxActivations`.

- over the ceiling → `.seatLimitExceeded(limit:used:)`
- exactly at it → valid, warns `.seatsExhausted` (this device is presumably one of them)

**Inapplicable without a provider that counts.** A local device cannot know how
many other machines are active, and guessing is worse than not checking.

### `VersionBoundRule`

Enforces the perpetual-fallback ceiling. Fails with
`.versionNotCovered(running:bound:)`.

Inapplicable when `applicationVersion` is `nil`, which is the case outside an app
bundle — better than enforcing a bound against a guessed version.

### `OfflineGraceRule`

Bounds how long the app runs on a cached answer.

- `connectivity == .online` → passes; a live check re-establishes freshness
- staleness > grace → `.offlineGraceExhausted(staleBy:)`
- staleness > 75% of grace → valid, warns `.withinOfflineGrace`
- never validated, currently offline → fails; there is no evidence the provider ever accepted it

Inapplicable when `offlineGraceInterval` is `nil` — unlimited offline use, the
right default for signed offline licenses.

### `ClockTamperRule`

```swift
ClockTamperRule(tolerance: .licenseDays(1))
```

Compares now against the furthest-forward instant ever recorded. A regression
beyond tolerance fails with `.clockTampering(observed:highWaterMark:)`.

The tolerance is not laziness. NTP corrections, dead coin cells, and travel across
a date line all move clocks backwards legitimately, and punishing an honest user
whose clock is simply wrong costs more than the trial-extension it prevents.

Requires a `timeAnchor`. Use `UserDefaultsTimeAnchor()` so it survives relaunch;
`InMemoryTimeAnchor` only detects tampering within one session.

## Warnings

Valid, but worth surfacing. Folding these into failures would force you to choose
between locking a customer out and saying nothing about an imminent expiry.

| Warning | Meaning |
|---|---|
| `.expiringSoon(remaining:)` | Inside the warning threshold. |
| `.withinExpiryGrace(expiredAt:graceEndsAt:)` | Past expiry, still covered. |
| `.withinOfflineGrace(staleBy:graceEndsAt:)` | Overdue for an online check. |
| `.unsigned` | No signature, and policy tolerates that. |
| `.providerUnreachable` | Status may be stale. |
| `.seatsExhausted(limit:)` | At the ceiling; the next machine will fail. |
| `.custom(rule:message:)` | From one of your rules. |

```swift
if report.isRunningOnGrace {
    banner(report.summary)      // "The license expires in 3 days."
}
```

## Acting on failures

```swift
for failure in report.failures {
    switch failure {
    case .expired, .revoked:
        showRenewalPrompt()
    case .machineMismatch, .seatLimitExceeded:
        showSeatManagement()          // "release another device"
    case .offlineGraceExhausted:
        showReconnectPrompt()         // NOT a renewal prompt
    case .versionNotCovered(_, let bound):
        showUpgradePrompt(coveredUpTo: bound.maximumVersion)
    case .signatureInvalid, .signatureMissing:
        showSupportContact()          // do not offer a retry; it will not help
    case .unknownSigningKey:
        showAppUpdatePrompt()         // your build is older than the license
    case .clockTampering:
        showClockPrompt()             // "check your date & time settings"
    default:
        showGenericProblem(report.summary)
    }
}
```

Two worth calling out. `.offlineGraceExhausted` is **not** an expiry — the license
is fine, the device just needs to reach the internet, and offering a renewal
button here asks a paying customer to pay twice. And `.unknownSigningKey` usually
means your app predates the key that signed the license: the fix is updating the
app, not the license.

## Custom rules

The extension point for policy the SDK does not ship.

```swift
let domainRule = ClosureRule(id: "site.emailDomain") { context in
    guard let email = context.license.subject.email else {
        return .notApplicable
    }
    guard email.hasSuffix("@acme.example") else {
        return .failed(.custom(rule: "site.emailDomain",
                               message: "not a licensed email domain"))
    }
    return .satisfied
}

let validator = LicenseValidator.connectedDefault().adding([domainRule])
```

Or as a type, when it needs configuration:

```swift
struct MaximumDevicesRule: LicenseRule {
    let id: RuleIdentifier = "host.maximumDevices"
    let ceiling: Int

    func evaluate(_ context: ValidationContext) async throws -> RuleOutcome {
        guard let used = context.record.providerState.activationCount else {
            return .notApplicable
        }
        guard used <= ceiling else {
            return .failed(.custom(rule: id.rawValue,
                                   message: "\(used) devices exceeds the \(ceiling) allowed"))
        }
        return used == ceiling
            ? .satisfied(warnings: [.custom(rule: id.rawValue, message: "device limit reached")])
            : .satisfied
    }
}
```

### Rules for writing rules

**Return `.notApplicable`, not `.satisfied`, when there is nothing to check.** A
report should never imply a check ran when it did not — that distinction is what
makes `debugDescription` trustworthy during a support call.

**Be a pure function of the context.** Do not read `Date()`, `UserDefaults`, or a
network. Everything you need is on the context; anything missing should be passed
through `userInfo`. Rules that reach outside cannot be tested and break when the
chain is reordered.

**Do not perform I/O.** The chain runs on every validation, including feature
gates. A rule that makes a network call turns `isEntitled(to:)` into a request.

**Fail closed.** A rule that throws is recorded as a **failure**, never a pass, so
one misbehaving custom rule cannot silently open a gate. Rely on that rather than
swallowing your own errors.

### Removing rules

```swift
LicenseValidator.connectedDefault().removing([.machineBinding, .seatLimit])
```

Legitimate for a floating-license model where any device may use any seat. Removing
`.signature` is not — at that point nothing distinguishes a real license from a
text file someone typed.

## Testing

Every input is injectable, so rules test as pure functions:

```swift
@Test func expiredLicenseIsRejected() async {
    let expiry = Date(timeIntervalSince1970: 1_700_000_000)
    let record = /* … a record expiring at `expiry` … */

    let report = await LicenseValidator(rules: [ValidityWindowRule()])
        .validate(ValidationContext(record: record, now: expiry.addingTimeInterval(60)))

    #expect(report.failures.contains(.expired(at: expiry)))
}
```

No sleeping, no clock mocking beyond passing a `Date`, no network.

## Next

- [Licensing model](licensing-model.md) — the fields these rules read
- [Providers](providers.md) — where `providerState` comes from
- [Troubleshooting](troubleshooting.md) — when a license is rejected and you disagree
