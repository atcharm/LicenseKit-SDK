import Foundation
import LicenseKit

/// The demo's key material.
///
/// - Warning: These keys are published in a public example. They are worthless
///   — they sign licenses for a product that does not exist, trusted only by
///   this demo — but the *shape* of the mistake they model is real: the private
///   key below must never appear in an app you ship. It lives in `DemoBackstage`
///   because that target stands in for your server.
///
/// Generate your own with the bundled command-line tool:
///
/// ```sh
/// licensekit keygen --key-id vendor-2026 --out ./keys
/// ```
///
/// You get a `.public` key to embed in your app and a `.private` key to guard.
/// Losing the private key means you can never issue another license existing
/// installs accept; leaking it means anyone can.
public enum DemoVendorKeys {
    /// The key identifier carried in every signature. Verification selects by
    /// this, which is what makes rotation possible: ship the new public key
    /// alongside the old one and keep both trusted until the last license
    /// signed with the old one has expired.
    public static let keyID = "demo-2026"

    /// Embedded in the app. Public keys are not secret — one discloses nothing
    /// and cannot be used to forge anything.
    public static let publicKeyBase64 = "OIgVKdhyB4hWscPd/v8UWvFtrv8pxkvPzjUYEeomYUI="

    /// Vendor-side only. See the warning above.
    static let privateKeyBase64 = "oMQcdJjzCvWTp1T0ppkehKYEb68MNu5AgRX9AYbVfws="

    /// A second key pair the app does *not* trust, so the demo can show what a
    /// license signed by an unrecognised issuer looks like.
    static let untrustedKeyID = "rogue-2026"
    static let untrustedPrivateKeyBase64 = "ln2XYy/U85vfaaG7eSk9ddfufY3Q+jxpqNUymB0WTag="

    /// Symmetric key used to seal (encrypt) license containers.
    ///
    /// Sealing keeps a license file's contents private in transit and makes
    /// casual editing fail loudly. It is **not** what makes a license
    /// trustworthy: an app that opens sealed files must carry this key, and
    /// anything shipped in a binary can be extracted. Licenses are signed first
    /// and sealed second precisely so authenticity survives this key leaking.
    public static let sealingKeyBase64 = "74a9dO4geIazIiQdY/64MYWaYkvS34XkOkIulGc5SYA="

    /// The trust anchor the app installs. One entry today; add the next key here
    /// the release *before* you start signing with it.
    public static var trustedPublicKeys: [(id: String, base64: String)] {
        [(id: keyID, base64: publicKeyBase64)]
    }

    static func signingKey() throws -> LicenseSigningKey {
        try LicenseSigningKey(id: KeyIdentifier(rawValue: keyID), base64: privateKeyBase64)
    }

    static func untrustedSigningKey() throws -> LicenseSigningKey {
        try LicenseSigningKey(
            id: KeyIdentifier(rawValue: untrustedKeyID),
            base64: untrustedPrivateKeyBase64
        )
    }

    public static func sealingKey() throws -> LicenseSealingKey {
        try LicenseSealingKey(base64: sealingKeyBase64)
    }
}
