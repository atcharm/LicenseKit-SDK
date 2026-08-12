import DemoBackstage
import Foundation
import LicenseKit
import SwiftUI

// MARK: - Outcome of an operation

/// What to tell the user after a licensing call returned.
///
/// Deliberately more than a string. A licensing failure almost always has a
/// *next step*, and which step depends on the structured reason — which is why
/// LicenseKit returns typed failures instead of formatted messages.
struct DemoOutcome: Identifiable, Sendable {
    enum Kind: Sendable {
        case success, warning, failure
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    /// The remedy to offer. Absent when there is nothing useful to suggest.
    let hint: String?

    static func success(_ title: String, _ message: String) -> DemoOutcome {
        DemoOutcome(kind: .success, title: title, message: message, hint: nil)
    }

    var symbol: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}

extension DemoOutcome {
    /// Turns an error thrown by `LicenseManager` into something worth showing.
    ///
    /// Note that `localizedDescription` is already user-facing for every
    /// LicenseKit error — the SDK writes those strings for display, not for logs.
    /// What this adds is the branch a real app needs: the same "activation
    /// failed" banner is the wrong response to a seat limit, a refund, and a
    /// flat tyre on the network.
    init(_ error: any Error, operation: String) {
        guard let kitError = error as? LicenseKitError else {
            self.init(
                kind: .failure,
                title: "\(operation) failed",
                message: error.localizedDescription,
                hint: nil
            )
            return
        }

        switch kitError {
        case .provider(let providerError):
            self.init(
                kind: providerError.isTransient ? .warning : .failure,
                title: providerError.isTransient
                    // The distinction is worth spelling out in the UI. A
                    // transient failure means "try again"; a definitive one
                    // means "trying again cannot help".
                    ? "\(operation) could not reach the service"
                    : "\(operation) was refused",
                message: providerError.errorDescription ?? "The provider refused the request.",
                hint: Self.hint(for: providerError)
            )

        case .validation(let report):
            self.init(
                kind: .failure,
                title: "\(operation) produced a license this app rejects",
                message: report.summary,
                // The license was *not* stored — LicenseKit refuses to persist
                // something it will reject on every launch. So the remedy is
                // about the license, not about retrying.
                hint: report.failures.first.map { Remedy(for: $0).explanation }
            )

        case .format(let formatError):
            self.init(
                kind: .failure,
                title: "\(operation) could not read the license",
                message: formatError.errorDescription ?? "The file is not readable.",
                hint: Self.hint(for: formatError)
            )

        case .storage(let storageError):
            self.init(
                kind: .failure,
                title: "\(operation) could not use the license store",
                message: storageError.errorDescription ?? "Storage failed.",
                hint: "Try the in-memory store in Setup. An unsigned binary is "
                    + "often refused by the data-protection keychain, which is "
                    + "what this demo is when run with `swift run`."
            )

        case .noActiveLicense:
            self.init(
                kind: .warning,
                title: "Nothing to \(operation.lowercased())",
                message: "No license is installed.",
                hint: "Activate a key, or install one of the license files."
            )

        case .misconfigured(let reason):
            self.init(
                kind: .failure,
                title: "LicenseKit is misconfigured",
                message: reason,
                hint: "Check the provider list and its capabilities in Setup."
            )

        default:
            self.init(
                kind: .failure,
                title: "\(operation) failed",
                message: kitError.localizedDescription,
                hint: nil
            )
        }
    }

    private static func hint(for error: LicenseProviderError) -> String? {
        switch error {
        case .seatLimitReached:
            return "Release a seat on another device, or raise the seat count. "
                + "The Service screen can free seats for you."
        case .licenseNotFound:
            return "Check the key. The Activate screen lists every key this "
                + "demo service knows about."
        case .unreachable, .timedOut:
            return "This is transient, so an installed license keeps working "
                + "under its grace period. Nothing is revoked."
        case .rateLimited:
            return "The retry policy already honoured Retry-After and gave up. "
                + "Back off before asking again."
        case .unauthorized:
            return "Your app's credentials were refused. Retrying will not help; "
                + "this is a vendor-side configuration problem."
        case .malformedResponse:
            return "The service answered in a shape the adapter cannot read. "
                + "Worth logging loudly — it usually means an API change."
        case .rejected:
            return "A settled answer from the provider, not a network problem."
        default:
            return nil
        }
    }

    private static func hint(for error: LicenseFormatError) -> String? {
        switch error {
        case .malformedContainer:
            return "If the file is sealed, the reader needs the sealing key — "
                + "turn it back on in Setup."
        case .decodingFailed(let reason) where reason.contains("licenses"):
            return "A container holding several licenses needs "
                + "`LicenseFileReader.read(_:)`; `installLicenseFile(_:)` "
                + "handles exactly one."
        case .unsupportedContainerVersion:
            return "The file was written by a newer version of the vendor tooling."
        default:
            return nil
        }
    }
}

// MARK: - Remedies

/// The action a particular validation failure calls for.
///
/// This mapping is the reason `ValidationFailureReason` is a structured enum
/// rather than a message. Offering the wrong remedy is worse than offering none:
/// `.offlineGraceExhausted` means the license is fine and the device needs the
/// internet, so a renewal button there asks a paying customer to pay twice.
struct Remedy: Sendable {
    let label: String
    let explanation: String
    let symbol: String

    init(for failure: ValidationFailureReason) {
        switch failure {
        case .expired, .revoked:
            self.init(
                label: "Renew",
                explanation: "The term has ended or the provider withdrew it. "
                    + "This is the one case where asking for money is right.",
                symbol: "creditcard"
            )

        case .machineMismatch, .seatLimitExceeded:
            self.init(
                label: "Manage devices",
                explanation: "The license is real; it is in use elsewhere. "
                    + "Offer seat management, not a purchase.",
                symbol: "desktopcomputer"
            )

        case .offlineGraceExhausted:
            self.init(
                label: "Reconnect",
                explanation: "The license is valid. It has simply gone too long "
                    + "without checking in. Do not offer a renewal here.",
                symbol: "wifi.exclamationmark"
            )

        case .versionNotCovered(_, let bound):
            self.init(
                label: "Use \(bound.maximumVersion) or earlier",
                explanation: "A perpetual fallback: the customer keeps what they "
                    + "paid for. Offer an upgrade, and never disable the "
                    + "versions they own.",
                symbol: "arrow.down.app"
            )

        case .signatureInvalid, .signatureMissing:
            self.init(
                label: "Contact support",
                explanation: "The claim set does not match its signature, so the "
                    + "file was edited after issuing. Retrying cannot fix it.",
                symbol: "lifepreserver"
            )

        case .unknownSigningKey:
            self.init(
                label: "Update the app",
                explanation: "The license was signed by a key this build does "
                    + "not carry — usually a license newer than the app. This is "
                    + "distinct from a forgery on purpose.",
                symbol: "arrow.down.circle"
            )

        case .clockTampering:
            self.init(
                label: "Fix the date",
                explanation: "The system clock is behind a time the SDK already "
                    + "observed. Often a genuinely wrong clock rather than an "
                    + "attack, so say so gently.",
                symbol: "clock.badge.exclamationmark"
            )

        case .productMismatch:
            self.init(
                label: "Wrong product",
                explanation: "A valid license for something else in the same "
                    + "catalogue. Name the product they need.",
                symbol: "shippingbox"
            )

        case .notYetValid:
            self.init(
                label: "Not started yet",
                explanation: "A pre-order, or a clock that is behind. Show the "
                    + "start date rather than an error.",
                symbol: "calendar.badge.clock"
            )

        default:
            self.init(
                label: "Contact support",
                explanation: failure.description,
                symbol: "questionmark.circle"
            )
        }
    }

    private init(label: String, explanation: String, symbol: String) {
        self.label = label
        self.explanation = explanation
        self.symbol = symbol
    }
}

// MARK: - State presentation

extension LicenseState {
    /// The four situations a licensing UI actually has to draw.
    ///
    /// `LicenseState` has three cases, but "valid" and "valid only because a
    /// grace period is covering it" want different treatment — the second needs
    /// a persistent, actionable banner.
    enum Appearance {
        case licensed, grace, invalid, unlicensed

        var title: String {
            switch self {
            case .licensed: return "Licensed"
            case .grace: return "Licensed — action needed"
            case .invalid: return "Not valid"
            case .unlicensed: return "No license"
            }
        }

        var symbol: String {
            switch self {
            case .licensed: return "checkmark.seal.fill"
            case .grace: return "exclamationmark.triangle.fill"
            case .invalid: return "xmark.seal.fill"
            case .unlicensed: return "lock.fill"
            }
        }

        var tint: Color {
            switch self {
            case .licensed: return .green
            case .grace: return .orange
            case .invalid: return .red
            case .unlicensed: return .secondary
            }
        }
    }

    var appearance: Appearance {
        switch self {
        case .unlicensed:
            return .unlicensed
        case .licensed(_, let report):
            return report.isRunningOnGrace ? .grace : .licensed
        case .invalid:
            return .invalid
        }
    }
}

extension RuleOutcome {
    var symbol: String {
        switch self {
        case .satisfied(let warnings): return warnings.isEmpty ? "checkmark" : "exclamationmark.triangle"
        case .failed: return "xmark"
        case .notApplicable: return "minus"
        }
    }

    var tint: Color {
        switch self {
        case .satisfied(let warnings): return warnings.isEmpty ? .green : .orange
        case .failed: return .red
        case .notApplicable: return .secondary
        }
    }

    var summary: String {
        switch self {
        case .satisfied(let warnings) where warnings.isEmpty:
            return "passed"
        case .satisfied(let warnings):
            return warnings.map(\.description).joined(separator: " ")
        case .failed(let reason):
            return reason.description
        case .notApplicable:
            return "nothing to check"
        }
    }
}

extension MetadataValue {
    /// A one-line rendering for display.
    ///
    /// `MetadataValue` is frozen, so this switch stays exhaustive in both the
    /// source and the binary distribution — no `default` needed.
    var display: String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .double(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .date(let value): return DemoFormat.timestamp(value)
        case .null: return "null"
        }
    }
}

// MARK: - Formatting

enum DemoFormat {
    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// Renders a duration the way a licensing UI should: in days once it is more
    /// than a day, because "expires in 3,542,400 seconds" helps nobody.
    static func duration(_ interval: TimeInterval) -> String {
        let magnitude = abs(interval)
        if magnitude >= .licenseDays(1) {
            let days = (magnitude / 86_400).rounded()
            return "\(Int(days)) day\(days == 1 ? "" : "s")"
        }
        if magnitude >= .licenseHours(1) {
            let hours = (magnitude / 3_600).rounded()
            return "\(Int(hours)) hour\(hours == 1 ? "" : "s")"
        }
        let minutes = max(1, (magnitude / 60).rounded())
        return "\(Int(minutes)) minute\(minutes == 1 ? "" : "s")"
    }

    static func expiry(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let remaining = date.timeIntervalSince(now)
        let stamp = timestamp(date)
        return remaining >= 0
            ? "\(stamp) — in \(duration(remaining))"
            : "\(stamp) — \(duration(remaining)) ago"
    }

    static func offset(_ interval: TimeInterval) -> String {
        interval == 0
            ? "none (system time)"
            : "\(interval > 0 ? "+" : "−")\(duration(interval))"
    }

    static func seats(_ record: LicenseRecord) -> String {
        let limit = record.license.policy.seats.maxActivations
        let used = record.providerState.activationCount
        switch (used, limit) {
        case (let used?, let limit?): return "\(used) of \(limit) in use"
        case (let used?, nil): return "\(used) in use, no ceiling"
        case (nil, let limit?): return "\(limit) seat\(limit == 1 ? "" : "s"), usage not reported"
        case (nil, nil): return "unlimited"
        }
    }
}
