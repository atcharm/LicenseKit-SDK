# LicenseKit documentation

| Guide | Read it when |
|---|---|
| [Getting started](getting-started.md) | Installing, issuing a first license, wiring it into an app. |
| [Licensing model](licensing-model.md) | Deciding how to model your pricing — kinds, entitlements, seats, grace. |
| [Validation](validation.md) | Understanding why a license was rejected, or adding a rule of your own. |
| [Providers](providers.md) | Connecting a store, or writing an adapter for one that is not included. |
| [Issuing](issuing.md) | Running the vendor side — keys, rotation, signing, sealing, CSV, CLI. |
| [Storage](storage.md) | Choosing where records live, or writing a custom store. |
| [Architecture](architecture.md) | Understanding why the pieces are shaped the way they are. |
| [Security](security.md) | Threat modelling, key handling, or a security review. |
| [Recipes](recipes.md) | Trials, subscriptions, site licenses, seat management, migration. |
| [Troubleshooting](troubleshooting.md) | Anything is wrong. ~40 symptom → cause → fix entries. |

## The short version

A **license** is a set of claims a vendor signs: who bought what, until when, on
how many machines, with which capabilities. The signature is the only thing that
makes it trustworthy. Everything else in the SDK is plumbing around that fact.

Five rules carry most of the weight:

1. **The core knows nothing about vendors.** `LicenseKitCore` has no networking,
   no cryptography, and no persistence, so a Gumroad detail *cannot* leak into it.
   Adding a provider is one file.

2. **Only `License` is signed; `LicenseRecord` holds everything mutable.** That
   is what lets a renewal move an expiry date without reissuing, and what makes
   local tampering able to remove privileges but never add them.

3. **Signatures cover a hand-written canonical byte form, never `Codable`
   output.** `JSONEncoder` output is not a stable contract, and a change to it
   invalidates every issued license — silently, on customers' machines only.

4. **Sign first, seal second.** Encryption is confidentiality; the signature is
   authenticity. A symmetric key inside a shipped app can be extracted, so
   authenticity must not depend on it.

5. **Only a definitive provider answer changes local status.** A timeout is not a
   revocation. Conflating them is how a café Wi-Fi turns into a support ticket
   claiming your app "deactivated itself".

Each rule has a specific failure attached to violating it, which is what
[troubleshooting.md](troubleshooting.md) indexes.

## Reading order

**Shipping an app with licensing:**
[Getting started](getting-started.md) → [Licensing model](licensing-model.md) →
[Issuing](issuing.md). Read [Security](security.md) before you go live.

**Connecting a store:**
[Getting started](getting-started.md) → [Providers](providers.md).

**Reviewing it:** [Security](security.md) →
[Architecture](architecture.md#5-the-canonical-form). The canonical form and the
sign-then-seal ordering are the two places where a subtle mistake is expensive.

## The `licensekit` tool

Several guides here use the `licensekit` command line tool. It is the vendor-side
utility — you need it to issue licenses, not to validate them — and it is attached
to every release:

```sh
curl -fsSLO https://github.com/gumbracelet/LicenseKit-SDK/releases/download/1.0.0/licensekit.artifactbundle.zip
unzip -q licensekit.artifactbundle.zip
install licensekit.artifactbundle/licensekit-1.0.0-macos/bin/licensekit /usr/local/bin/
```

`licensekit --help` lists every command. [Issuing](issuing.md#cli-reference) is
the full reference.

## Vocabulary

Worth fixing early, because several of these look interchangeable and are not.

| Term | Means |
|---|---|
| **License** | The signed claim set. Immutable, identical on every device. |
| **LicenseRecord** | A license *plus* local state: activation, provider status, last validation. Unsigned. |
| **License key** | The customer-facing string (`ABCD-EFGH-…`). A bearer credential. |
| **License ID** | The durable primary key. Survives a key being reissued. |
| **Entitlement** | A capability the license unlocks, e.g. `"export.pdf"`. |
| **Source** | A read-only table of licenses (CSV, bundled manifest). No seats, no network. |
| **Provider** | An authority you ask permission from (Gumroad, Polar, your backend). |
| **Seat** | One machine's claim on a license. |
| **Sealing** | Symmetric encryption of a license container. Not a trust mechanism. |
| **Canonical form** | The exact bytes a signature covers. |
