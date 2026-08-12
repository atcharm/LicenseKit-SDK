import DemoBackstage
import Foundation
import LicenseKit

/// One line in the Activity screen.
struct ActivityEntry: Identifiable, Sendable, Hashable {
    /// Who produced the line. Keeping these apart is the whole value of the
    /// screen: it makes it obvious that a retry came from the SDK and a 503 came
    /// from the service, rather than leaving both as "something happened".
    enum Source: String, CaseIterable, Identifiable, Sendable {
        /// `LicenseKitConfiguration.log` — the SDK's own diagnostics.
        case sdk
        /// The stand-in server, which in production is not your code at all.
        case service
        /// The demo app: what the user asked for and what came back.
        case app

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sdk: return "SDK"
            case .service: return "Service"
            case .app: return "App"
            }
        }
    }

    let id = UUID()
    let at: Date
    let source: Source
    let level: LicenseLogLevel
    let message: String
}

/// Collects diagnostics from three concurrent producers and delivers them in
/// order to the main actor.
///
/// The SDK's `LicenseLogging` is called synchronously from whatever context is
/// doing licensing work, and the demo service logs from its own actor. Neither can
/// touch `@MainActor` state directly, so both hand entries to an `AsyncStream` and
/// the model drains it. That keeps ordering intact, which a `Task { @MainActor }`
/// per message would not.
final class ActivityRecorder: Sendable {
    let stream: AsyncStream<ActivityEntry>
    private let continuation: AsyncStream<ActivityEntry>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<ActivityEntry>.makeStream(
            // A demo can generate a lot of chatter; drop the oldest rather than
            // growing without bound.
            bufferingPolicy: .bufferingNewest(1_000)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func record(_ source: ActivityEntry.Source, _ level: LicenseLogLevel, _ message: String) {
        // Wall-clock, deliberately not the adjustable clock: the log is a record
        // of what happened in this session, not of what the licensing rules
        // believe the date to be.
        continuation.yield(
            ActivityEntry(at: Date(), source: source, level: level, message: message)
        )
    }

    /// Plugs into `LicenseKitConfiguration.log`.
    ///
    /// The SDK only ever passes redacted strings — no license keys, no subject
    /// PII — which is what makes it safe to show this in a UI at all. It writes to
    /// no log of its own, so where diagnostics go is entirely the host's choice.
    var licenseLog: any LicenseLogging {
        CallbackLicenseLog(minimumLevel: .debug) { [self] level, message in
            record(.sdk, level, message)
        }
    }

    /// Plugs into `DemoStoreBackend`, standing in for a server's request log.
    var serviceSink: DemoEventSink {
        DemoEventSink { [self] message in
            record(.service, .info, message)
        }
    }

    func app(_ message: String, level: LicenseLogLevel = .info) {
        record(.app, level, message)
    }
}
