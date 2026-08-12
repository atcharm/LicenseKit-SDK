# Issuing

The vendor side: keys, signing, sealing, batch import, and the CLI.

> Everything here uses `LicenseKitVendor`, which contains the private signing key
> type. **It must never be linked into a shipping app.** Put it in a fulfilment
> backend, a build script, or the bundled `licensekit` tool.

## Keys

### Generating

```sh
licensekit keygen --key-id vendor-2026 --sealing --out ./keys
```

```swift
let (signing, verification) = try LicenseSigningKey.generate(id: "vendor-2026")
let sealingKey = LicenseSealingKey.generate()
```

| Algorithm | When |
|---|---|
| `.ed25519` (default) | Almost always. Small keys, small signatures, no parameters to get wrong, constant-time by construction. |
| `.ecdsaP256` | You have an existing P-256 hierarchy or an HSM that cannot do Ed25519. |

### Handling

| Key | Secret? | Storage |
|---|---|---|
| `.public` | No | Embed in the app, commit to the repo, publish it |
| `.private` | **Yes** | Secrets manager, HSM, or an encrypted offline backup |
| `.seal` | Yes-ish | Same as private, but see [Sealing](#sealing) — it ends up in your app anyway |

The private key has two failure modes, and they are not symmetric:

- **Leaked** — anyone can mint licenses your app accepts. Recovery means shipping
  an app update trusting a new key *and* reissuing every outstanding license.
- **Lost** — you can never issue another license that already-shipped apps
  accept. There is no recovery at all. Back it up in more than one place.

The CLI writes `.private` and `.seal` with `0600` permissions. The repo's
`.gitignore` excludes `*.private`, `*.seal`, and `keys/` — check that this
survives into your own repository.

### Rotation

Rotation works because a signature names the key that made it, and a verifier can
hold several:

```swift
let verifier = CryptoKitLicenseVerifier(keys: [key2025, key2026])
```

The sequence:

1. Ship an app trusting **both** the current key and a future one.
2. Later, start signing new licenses with the new key.
3. Keep trusting the old key until every license signed with it has expired.
4. Drop the old key in a subsequent release.

> **Do this from version 1.** If your first release trusts only one key ID,
> rotating later requires an app update *and* reissuing every outstanding license
> at the same moment. Ship trusting two key IDs even if the second key does not
> exist yet — you can generate it the day you need it.

A license signed by a key your app does not know fails with `.unknownSigningKey`,
which is distinct from `.signatureInvalid` precisely so you can tell "your build is
too old" from "this is forged".

## Issuing

### From a specification

```swift
let issuer = LicenseIssuer(signingKey: signingKey)

let signed = try issuer.issue(
    .subscription(
        product: ProductReference(id: "com.example.app", name: "Example App"),
        issuer: "com.example.licensing",
        expiresAt: renewalDate,
        subject: LicenseSubject(name: order.name, email: order.email),
        entitlements: [Entitlement(id: "export.pdf")],
        seats: 3,
        offlineGrace: .licenseDays(30),
        expiryGrace: .licenseDays(3)
    )
)
```

Convenience constructors: `.perpetual`, `.subscription`, `.trial`. For anything
else, build a `LicenseSpecification` field by field.

A specification is plain data — storable, diffable, generatable from a purchase
record, checkable into a fixture. Issuance adds only a timestamp and a signature,
which is what keeps it reproducible and reviewable.

### Output forms

```swift
try issuer.package(signed)            // Data — binary container to attach
try issuer.issueFile(specification)   // issue + package in one call
try issuer.issueText(specification)   // base64 text, wrapped at 64 columns
try issuer.package([signed1, signed2]) // one container, many licenses
```

`issueText` wraps at 64 columns so the blob survives being quoted in a mail
client, which is where license text usually gets mangled. The reader strips
whitespace on the way back in, so a customer pasting a mauled block still works.

### Generated keys

```swift
LicenseKeyFormat(groupCount: 4, groupLength: 5, separator: "-", prefix: "STUDIO")
// STUDIO-3F7KM-9WQ2X-B4NPR-VT8HZ
```

The default is 4 groups of 5 from a 32-symbol alphabet — 100 bits of entropy, far
beyond guessing, and still readable over the phone.

The alphabet excludes `I`, `L`, `O`, and `U`. The first three are indistinguishable
from `1` and `0` in most fonts; excluding `U` keeps generated keys from spelling
anything unfortunate. Every exclusion is one support email you do not receive.

Generation uses `SystemRandomNumberGenerator`, which is CSPRNG-backed. Never
substitute a seeded generator — predictable keys let anyone enumerate valid
licenses.

## Sealing

Sealing encrypts the container. Before you enable it, understand what it does and
does not buy.

```swift
let issuer = LicenseIssuer(
    signingKey: signingKey,
    sealingKey: sealingKey,
    sealAlgorithm: .chaChaPoly,
    keyHint: "vendor-2026"
)
```

**What it does:** hides license contents in transit and at rest, and makes casual
tampering fail loudly with a decryption error rather than a validation error.

**What it does not do:** establish authenticity. Your app must carry the symmetric
key to open the file, and anything in a shipped binary can be extracted with
`strings` and patience.

Because of that, LicenseKit always **signs first and seals second**. Authenticity
rests on a private key that never leaves your control, so it survives the sealing
key leaking — which, given enough customers and enough time, it will.

**Shipping unsealed signed licenses is a sound choice.** You lose nothing
security-relevant and gain support tickets you can actually read. Reach for
sealing when license contents are commercially sensitive (customer names, contract
terms in metadata), not because it sounds safer.

| Algorithm | When |
|---|---|
| `.chaChaPoly` (default) | Constant-time in software everywhere, including older watchOS and tvOS hardware. |
| `.aesGCM` | Hardware AES is present, or an existing key hierarchy standardises on it. |

The container header is fed to the AEAD as additional authenticated data, so
editing the header makes decryption fail rather than steering the reader into
misinterpreting the payload.

### Reading sealed files in the app

```swift
let reader = LicenseFileReader.sealed(key: sealingKey)
try await licensing.installLicenseFile(data, reader: reader)
```

Unsealed files need no key at all — `LicenseFileReader()` reads them, and an app
that ships unsealed licenses links no symmetric crypto.

## Issuing from a CSV table

Vendors work in spreadsheets. Finance exports a customer list; you need signed
licenses. `CSVLicenseImporter` is that bridge — it turns an editable table into
licenses that cannot be altered without detection.

```sh
licensekit import-csv --in customers.csv \
  --signing-key-file ./keys/vendor-2026.private --key-id vendor-2026 \
  --product com.example.app --issuer com.example.licensing \
  --out site.licenses
```

```swift
let importer = CSVLicenseImporter(
    issuer: issuer,
    decoder: CSVLicenseDecoder(
        defaultProduct: "com.example.app",
        issuer: "com.example.licensing"
    )
)

let result = try importer.importLicenses(fromCSV: text)
result.signed        // [SignedLicense]
result.failures      // [(line: Int, reason: String)]
result.isComplete    // no failures
```

By default a bad row is collected rather than aborting the run. A 500-row import
that stops dead on row 200 wastes the operator's time; reporting every problem at
once lets them fix the table in one pass. Pass `continueOnError: false` (or
`--strict`) when partial output is worse than none.

### Columns

Every column name is configurable, because a license table is almost never
produced *for* this SDK — it is exported from a store, a CRM, or a spreadsheet a
finance team maintains.

| Default column | Maps to |
|---|---|
| `license_key` | **Required.** The key. |
| `license_id` | `LicenseID`; derived from the key when absent. |
| `product_id` | Falls back to `defaultProduct`. |
| `kind` | `perpetual`, `subscription`, `trial`, … |
| `customer_name`, `email`, `organization` | `LicenseSubject` |
| `issued_at`, `not_before`, `expires_at` | ISO-8601 or `yyyy-MM-dd` |
| `seats` | `SeatPolicy.maxActivations` |
| `entitlements` | Pipe-separated: `export.pdf\|sync.cloud` |
| `max_version` | `VersionBound.maximumVersion` |
| `meta_*` | `LicenseMetadata`, prefix stripped |

```swift
var mapping = CSVColumnMapping.default
mapping.licenseKey = "Licence Key"      // whatever finance calls it
mapping.customerEmail = "Contact Email"
```

Column lookup is case-insensitive, and a table containing nothing but keys is a
valid site-license manifest.

The parser is RFC 4180 — quoted delimiters (`"Acme, Inc."`), doubled quotes,
newlines inside fields, CRLF, and a UTF-8 BOM. Every one of those appears in real
exports, and every one silently corrupts a naive comma split.

**A license ID absent from the table is derived from the key**, not generated.
That matters: re-importing the same table must update the same records rather than
creating duplicates.

### Unsigned CSV as a runtime source

A table can also be read directly at runtime, without signing:

```swift
let source = CSVLicenseSource(
    contentsOf: manifestURL,
    decoder: CSVLicenseDecoder(defaultProduct: "com.example.app", issuer: "com.example.licensing")
)
```

**This is unsigned.** Anyone who can edit the file can grant themselves a license.
Acceptable for a managed fleet where the file arrives by MDM to a locked-down
device; wrong for anything a customer can reach. For public distribution, run the
table through the importer and ship the signed result.

## CLI reference

```
licensekit <command> [options]
```

### `keygen`

| Option | Meaning |
|---|---|
| `--key-id <id>` | Identifier recorded in signatures (default `primary`) |
| `--algorithm <name>` | `ed25519` (default) or `ecdsa-p256-sha256` |
| `--sealing` | Also generate a symmetric sealing key |
| `--out <directory>` | Write key files instead of printing |

### `issue`

Required: `--signing-key <base64>` (or `--signing-key-file <path>`), `--key-id`,
`--product`, `--issuer`.

| Option | Meaning |
|---|---|
| `--kind <kind>` | `perpetual` (default), `subscription`, `trial`, … |
| `--expires <date>` | ISO-8601, e.g. `2027-06-30` |
| `--seats <count>` | Maximum activations |
| `--entitlements <a\|b>` | Pipe-separated identifiers |
| `--name`, `--email`, `--organization` | Licensee details |
| `--license-key <key>` | Use this key instead of generating one |
| `--max-version <version>` | Perpetual-fallback ceiling |
| `--offline-grace <days>` | Offline grace window |
| `--sealing-key <base64>` | Encrypt the container |
| `--text` | Emit base64 text instead of binary |
| `--out <path>` | Write to a file instead of standard output |

### `inspect`

`--in <path>`, optional `--sealing-key`. Prints a license's contents.

### `verify`

`--in <path>`, `--public-key <base64>`, `--key-id <id>`; optional `--sealing-key`
and `--product`. Prints a rule-by-rule report and exits non-zero if any license is
invalid — usable as a CI gate.

### `import-csv`

`--in <path>` plus the signing options; optional `--out`, `--strict`.

### `canonical`

`--in <path>`. Prints the exact bytes a signature covers.

This is the debugging tool worth remembering. When a license verifies on one
machine and not another, run `canonical` on both and diff — the answer is always
in that output.

## Running an issuing service

A sketch of the shape that works:

```swift
// Load the signing key from your secrets manager at boot. Never from a file
// inside the deployment artefact.
let signingKey = try LicenseSigningKey(
    id: "vendor-2026",
    base64: try secrets.require("LICENSEKIT_SIGNING_KEY")
)
let issuer = LicenseIssuer(signingKey: signingKey)

func fulfil(_ order: Order) throws -> Data {
    try issuer.issueFile(
        .subscription(
            product: ProductReference(id: order.productID),
            issuer: "com.example.licensing",
            expiresAt: order.termEnd,
            subject: LicenseSubject(customerID: order.customerID, email: order.email),
            entitlements: entitlements(for: order.plan),
            seats: order.seats
        )
    )
}
```

Points worth building in from the start:

**Record what you issued.** Store the `LicenseID`, key, and specification. Support
will ask "what does this customer actually have?", and re-deriving it from a
signature is not possible.

**Make issuance idempotent.** Set `id` explicitly from your order ID so a retried
webhook reissues the same license rather than minting a second one.

**Keep the key out of the artefact.** Load from a secrets manager at boot. A
signing key baked into a container image is a signing key in your registry, your
CI logs, and everyone's laptop cache.

**Gate releases on `verify`.** Have CI issue a license with the production public
key and verify it. It catches a mismatched key pair before customers do.

## Next

- [Licensing model](licensing-model.md) — what to put in a specification
- [Security](security.md) — key handling and the threat model
- [Recipes](recipes.md) — trials, site licenses, migration
