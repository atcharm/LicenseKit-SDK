import DemoBackstage
import LicenseKit
import SwiftUI

/// Feature gates, driven by the live license state.
///
/// This is what all the rest of it is *for*. Note two things about the gate:
/// it asks about a capability (`export.raw`), never about a tier or a product
/// name; and it goes through `LicenseState.isEntitled(to:)`, which answers
/// `false` for an invalid or absent license without the caller having to remember
/// to check `isLicensed` first. The failure mode of a forgotten check is a paywall
/// bypass, so the safe answer is the built-in one.
struct FeaturesScreen: View {
    let model: LicensingModel

    /// A pretend action, so the gate has a consequence.
    @State private var lastAction: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro

                SectionCard(
                    title: "Capabilities",
                    subtitle: "Each row calls isEntitled(to:) on every state change. "
                        + "Change the license and watch them flip."
                ) {
                    VStack(spacing: 0) {
                        ForEach(DemoEntitlement.all) { descriptor in
                            FeatureRow(
                                descriptor: descriptor,
                                isEntitled: model.isEntitled(to: descriptor.id),
                                limit: model.limit(for: descriptor.id),
                                action: { lastAction = $0 }
                            )
                            if descriptor.id != DemoEntitlement.all.last?.id {
                                Divider().padding(.vertical, 10)
                            }
                        }
                    }
                }

                if let lastAction {
                    Callout(text: lastAction)
                }

                naming
            }
            .padding(20)
        }
    }

    private var intro: some View {
        SectionCard(
            title: "What the license unlocks",
            subtitle: summary
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    StatePill(state: model.state)
                    Text(grantedCount)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if case .invalid = model.state {
                    Callout(
                        kind: .warning,
                        text: "A license is installed but was rejected, so every gate "
                            + "is closed. The record is deliberately kept rather than "
                            + "discarded, so the UI can show which license failed and "
                            + "offer the right remedy."
                    )
                }
            }
        }
    }

    private var summary: String {
        switch model.state {
        case .licensed:
            return "Gates open as the license allows."
        case .invalid:
            return "Everything is closed: an installed license that fails validation "
                + "grants nothing."
        case .unlicensed:
            return "Everything is closed. This is what a user sees before they buy."
        }
    }

    private var grantedCount: String {
        let granted = DemoEntitlement.all.filter { model.isEntitled(to: $0.id) }.count
        return "\(granted) of \(DemoEntitlement.all.count) available"
    }

    private var naming: some View {
        SectionCard(
            title: "Why these names",
            subtitle: "Entitlement identifiers are permanent — a license granting "
                + "export.pdf cannot be edited afterwards."
        ) {
            Text("They are named after capabilities, never after tiers. “Pro” is a "
                + "marketing concept that changes with the pricing page; export.pdf "
                + "is a code concept that does not. Which plan grants which "
                + "capability is decided at issuance, so restructuring your pricing "
                + "never touches the gate in the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Row

private struct FeatureRow: View {
    let descriptor: DemoEntitlement.Descriptor
    let isEntitled: Bool
    let limit: Int?
    let action: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: descriptor.symbol)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isEntitled ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(descriptor.title).font(.callout.weight(.medium))
                    if !isEntitled {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(descriptor.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(descriptor.id.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if descriptor.usesLimit {
                    // A granted capability can carry a numeric ceiling. `nil` means
                    // either "not granted" or "no ceiling", so the two are
                    // distinguished by checking entitlement first.
                    Text(limitText)
                        .font(.caption)
                        .foregroundStyle(isEntitled ? .secondary : .tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(isEntitled ? "Run" : "Locked") {
                if isEntitled {
                    action("\(descriptor.title) ran. In a real app this is the point "
                        + "where the feature code executes.")
                } else {
                    action("\(descriptor.title) is gated. Show a paywall here, not an "
                        + "error — the user has done nothing wrong.")
                }
            }
            .controlSize(.small)
        }
    }

    private var limitText: String {
        guard isEntitled else { return "device limit: not granted" }
        guard let limit else { return "device limit: unbounded" }
        return "device limit: \(limit)"
    }
}
