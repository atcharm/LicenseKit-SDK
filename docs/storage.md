# Storage

Where license records live between launches.

## Choosing a store

| Store | Survives reinstall | Shareable | Use when |
|---|---|---|---|
| `InMemoryLicenseStore` | No | No | Tests; apps that re-activate every launch. |
| `FileLicenseStore` | macOS: yes · iOS: no | No | The default for most apps. |
| `KeychainLicenseStore` | Yes | Via access group | Licensing must outlive a reinstall, or an extension needs it. |

```swift
// Application Support — the usual choice
let store = try FileLicenseStore.applicationSupport(subdirectory: "com.example.app")

// Keychain — survives reinstall on iOS, shareable with extensions
let store = KeychainLicenseStore(
    service: "com.example.app",
    accessGroup: "TEAMID.com.example.shared",
    accessibility: .afterFirstUnlock
)

// No persistence at all — a legitimate production choice
let store = InMemoryLicenseStore()
```

"No persistence" deserves the mention. An app that activates against a provider on
every launch has no reason to keep a local copy, and not storing one removes a
whole class of stale-state bugs.

## What is safe to store

Records are stored as plain JSON, and that is deliberate.

A local record is derived from a license the user already holds — they can read it
in the file you gave them. More importantly, **the signature, not the storage
format, is what prevents a forged record from being honoured.** Encrypting the
store would obscure it from the user without changing what an attacker can achieve,
while making every support call harder.

What a user *can* do by editing the store is give themselves a worse license.
Editing the claim set breaks the signature; deleting the file means re-activating.
Neither is a threat.

Two exceptions worth knowing:

- Records contain `LicenseSubject` — a name and email. That is personal data, and
  it is on disk. Consider it when writing a privacy policy or handling a deletion
  request.
- `providerState.opaqueState` may carry provider continuation tokens. Treat those
  as you would any credential.

## `FileLicenseStore`

```swift
FileLicenseStore(url: url, serializer: JSONRecordSerializer())
```

- **Atomic writes.** A crash mid-write cannot leave a half-written file — which
  would make a licensed app look unlicensed on the next launch, the exact failure
  that turns a licensing bug into a refund request.
- **Owner-only permissions** (`0600`) where POSIX permissions exist.
- **Byte-stable output.** Records are written in sorted order, so an unchanged
  save produces an identical file and does not churn backups or sync tools.
- **Actor-isolated**, so concurrent saves serialise.

A missing file reads as *empty*, not as an error. First launch is not a failure.

```swift
try await store.destroy()   // delete the backing file entirely
```

### Where the file goes

`applicationSupport(subdirectory:)` resolves per-platform. Use a reverse-DNS
subdirectory so apps sharing a container do not collide.

On iOS the app container is removed with the app, so an uninstall/reinstall cycle
loses the license and the customer must re-activate. If that is unacceptable, use
the Keychain — but read the next section first, because it has a matching downside.

## `KeychainLicenseStore`

```swift
KeychainLicenseStore(
    service: "com.example.app",           // conventionally the bundle identifier
    account: "licensekit.records",
    accessGroup: nil,                     // shared group for app + extensions
    accessibility: .afterFirstUnlock
)
```

All records live in **one** keychain item. A licensing SDK stores a handful, and
one item means one atomic write rather than a multi-item update that can partially
fail.

### Accessibility

| Value | Readable |
|---|---|
| `.afterFirstUnlock` (default) | After the first unlock since boot, including in the background |
| `.whenUnlocked` | Only while unlocked |
| `.afterFirstUnlockThisDeviceOnly` | As above, and excluded from backups |

`.afterFirstUnlock` is the default because a background refresh that runs while
the screen is locked must not fail. `.whenUnlocked` will bite you the first time a
background task tries to validate.

On macOS the store opts into the data-protection keychain, so behaviour matches
the other platforms rather than depending on the legacy file-based keychain.

### The reinstall trade-off

Keychain items survive app deletion on iOS. That is usually the point — but it
cuts both ways:

- **Good:** a customer reinstalling keeps their license and does not re-activate.
- **Bad:** a customer who deletes the app to "start fresh" keeps the old license,
  including one that is expired or bound to a seat they wanted to release.

Note that `PlatformMachineIdentity`'s fallback identifier deliberately uses
`UserDefaults`, *not* the Keychain, for the same reason in reverse: a keychain-
persisted device ID would survive deletion forever, so a user who removes the app
would keep consuming a seat with no way to release it.

If you use the Keychain for records, give support a way to clear one.

## Custom stores

Five methods:

```swift
public protocol LicenseStore: Sendable {
    func loadAll() async throws -> [LicenseRecord]
    func record(for id: LicenseID) async throws -> LicenseRecord?
    func save(_ record: LicenseRecord) async throws      // upsert by id
    func remove(_ id: LicenseID) async throws
    func removeAll() async throws
}
```

`record(for:)` has a linear default; override it if your backend can index.

```swift
actor CloudBackedStore: LicenseStore {
    private let local: FileLicenseStore
    private let cloud: NSUbiquitousKeyValueStore

    func save(_ record: LicenseRecord) async throws {
        try await local.save(record)
        cloud.set(try encode(record), forKey: record.id.rawValue)
    }
    // …
}
```

Implementations must be safe to call concurrently — an actor is the easy way.

### Custom serialisation

```swift
struct ObfuscatedSerializer: LicenseRecordSerializing {
    func encode(_ records: [LicenseRecord]) throws -> Data { … }
    func decode(_ data: Data) throws -> [LicenseRecord] { … }
}

FileLicenseStore(url: url, serializer: ObfuscatedSerializer())
```

Both the file and Keychain stores accept one. Be honest with yourself about what
obfuscating the store buys: it raises the effort of *reading* a record, and
changes nothing about what a determined user can achieve, because the signature is
what the SDK actually trusts. It also makes every support call harder. Usually not
worth it.

## Multiple records

The stores hold many records keyed by `LicenseID`. Most apps have one.

```swift
try await store.mostRecentlyValidated()   // what `start()` uses
```

`LicenseManager` operates on a single active license. If you need several
simultaneously — a bundle of separately-licensed modules — hold one manager per
product, each with its own `product` identifier, sharing one store.

## Migration

Records are `Codable` with tolerant decoding: unknown fields are ignored, and
missing optional ones take defaults. Adding a field to a future version does not
break reading records written today.

Migrating **from another licensing SDK** means converting its stored state into a
`LicenseRecord`. See [recipes.md](recipes.md#migrating-from-another-sdk).

## Testing

```swift
let store = InMemoryLicenseStore([existingRecord])
```

For file behaviour, point a `FileLicenseStore` at a temporary URL and open a
*second* instance over the same path — that asserts about the file rather than an
in-memory cache:

```swift
try await FileLicenseStore(url: url).save(record)
let reopened = try await FileLicenseStore(url: url).loadAll()   // fresh instance
#expect(reopened.count == 1)
```

Keychain tests need an entitled host application; the file store is the better
target for CI.

## Next

- [Security](security.md) — what persistence does and does not protect
- [Architecture](architecture.md#3-the-five-seams) — where the store seam sits
