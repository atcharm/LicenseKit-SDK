import DemoBackstage
import LicenseKit
import SwiftUI

/// Controls for making the licensing service misbehave.
///
/// None of this is code you would ship — it stands in for a vendor dashboard, a
/// payment processor's webhook, and a bad hotel network. It exists because the
/// interesting licensing bugs only appear when the backend is unhealthy, and
/// arranging that for real is tedious.
///
/// The distinction to keep in mind while using it: **transient versus definitive**.
/// A timeout must not revoke a paying customer's license; a refund must not be
/// papered over by a retry. Every failure mode below is labelled with which it is.
struct ServiceScreen: View {
    let model: LicensingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                condition
                signing
                accounts
                reset
            }
            .padding(20)
        }
    }

    // MARK: - How the service behaves

    private var condition: some View {
        SectionCard(
            title: "Service health",
            subtitle: "Applies to every request. Retry and backoff live in "
                + "RemoteLicenseProvider, so they run for real against these failures."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Condition", selection: Binding(
                    get: { model.serviceCondition },
                    set: { newValue in Task { await model.setServiceCondition(newValue) } }
                )) {
                    ForEach(DemoStoreBackend.Condition.allCases) { condition in
                        Text(condition.title).tag(condition)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                HStack(spacing: 6) {
                    Text(model.serviceCondition.isTransient ? "transient" : "definitive")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (model.serviceCondition.isTransient ? Color.orange : Color.red)
                                .opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(model.serviceCondition.isTransient ? .orange : .red)

                    Text(model.serviceCondition.isTransient
                        ? "keeps the cached license and lets grace decide"
                        : "a settled answer; retrying cannot help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(model.serviceCondition.effect)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Callout(text: "Activate first, then break the service and press "
                    + "Refresh. A transient failure leaves the license alone; only a "
                    + "definitive answer from the provider revokes anything.")
            }
        }
    }

    private var signing: some View {
        SectionCard(
            title: "Does the service sign licenses?",
            subtitle: "Turning this off models a provider that relies on TLS for "
                + "authenticity instead of signing its payloads."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Return signed licenses", isOn: Binding(
                    get: { model.serviceSignsLicenses },
                    set: { newValue in Task { await model.setServiceSignsLicenses(newValue) } }
                ))

                Text("Whether that is acceptable is the host's call, not the "
                    + "provider's, and it is expressed through SignatureRule.Policy in "
                    + "Setup. With signatures Required, an unsigned license is "
                    + "rejected outright; with When present, it is accepted carrying "
                    + "an “unsigned” warning.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.serviceSignsLicenses && model.runtime.setup.signaturePolicy == .required {
                    Callout(
                        kind: .warning,
                        text: "Signatures are Required and the service has stopped "
                            + "signing, so activation will now fail validation. Activate "
                            + "a key to see it."
                    )
                }
            }
        }
    }

    // MARK: - Account operations

    private var accounts: some View {
        SectionCard(
            title: "Accounts",
            subtitle: "Things that happen in a dashboard, a webhook, or a card "
                + "retry — never in your app."
        ) {
            VStack(spacing: 0) {
                ForEach(model.accounts) { account in
                    ServiceAccountRow(account: account, model: model)
                    if account.id != model.accounts.last?.id {
                        Divider().padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private var reset: some View {
        SectionCard(title: "Start over", subtitle: nil) {
            Button("Reset the service") {
                Task { await model.resetService() }
            }
            .disabledWhileBusy(model.isBusy)
        }
    }
}

// MARK: - Row

private struct ServiceAccountRow: View {
    let account: DemoStoreBackend.Account
    let model: LicensingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(account.title).font(.callout.weight(.medium))
                StatusTag(status: account.status)
                Spacer()
                Text("seats \(account.seatsUsed)/\(account.seatLimit.map(String.init) ?? "∞")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(seatTint)
            }

            Text(account.key)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if let expiry = account.providerExpiresAt {
                Text("provider asserts expiry \(DemoFormat.expiry(expiry, now: model.clock.now))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Button("Revoke") { Task { await model.revoke(account.key) } }
                    .help("A chargeback. Activation is refused; an installed copy is "
                        + "revoked on the next refresh.")
                Button("Lapse") { Task { await model.lapse(account.key) } }
                    .help("A failed payment. Treated as expiry rather than revocation.")
                Button("Reinstate") { Task { await model.reinstate(account.key) } }
                Button("Renew +30d") { Task { await model.renew(account.key) } }
                    .help("Moves the asserted expiry forward without reissuing or "
                        + "resigning anything.")
                Button("Take a seat") { Task { await model.occupySeat(on: account.key) } }
                    .help("Occupies a seat from another machine, to reach the ceiling.")
                Button("Free seats") { Task { await model.releaseSeats(on: account.key) } }
            }
            .controlSize(.small)
            .disabledWhileBusy(model.isBusy)
        }
    }

    private var seatTint: Color {
        guard let limit = account.seatLimit else { return .secondary }
        if account.seatsUsed > limit { return .red }
        if account.seatsUsed == limit { return .orange }
        return .secondary
    }
}
