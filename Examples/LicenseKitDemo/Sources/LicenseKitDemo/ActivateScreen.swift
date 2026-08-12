import DemoBackstage
import LicenseKit
import SwiftUI

/// Redeeming a license key against a provider.
///
/// The activation call itself is one line. What this screen is really showing is
/// the surrounding shape a real app needs: a normalised key, a loading state, a
/// provider whose capabilities decide which buttons exist, and an error path that
/// distinguishes "no seats left" from "no such key" from "the Wi-Fi is down".
struct ActivateScreen: View {
    @Bindable var model: LicensingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                entry
                accountList
                capabilities
            }
            .padding(20)
        }
    }

    // MARK: - Key entry

    private var entry: some View {
        SectionCard(
            title: "Redeem a key",
            subtitle: "LicenseKey normalises itself, so “apert-studio-perpetual” "
                + "and “APERTSTUDIOPERPETUAL” are the same key. Do not upper-case "
                + "or strip separators in your own UI — that logic eventually "
                + "disagrees with the SDK's."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("APERT-STUDIO-PERPETUAL", text: $model.keyEntry)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { Task { await model.activate() } }

                    Button("Activate") {
                        Task { await model.activate() }
                    }
                    .keyboardShortcut(.defaultAction)
                }

                if !model.keyEntry.isEmpty {
                    Text("Normalised: \(LicenseKey(model.keyEntry).normalized)   ·   "
                        + "logged as: \(LicenseKey(model.keyEntry).redacted)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Refresh") { Task { await model.refresh() } }
                        .disabled(model.state.record == nil)
                    Button("Deactivate") { Task { await model.deactivate() } }
                        .disabled(!model.canDeactivate)
                    Button("Remove locally", role: .destructive) {
                        Task { await model.removeLicense() }
                    }
                    .disabled(model.state.record == nil)
                }

                Callout(text: "Try a key that does not exist to see licenseNotFound, "
                    + "then set the service to “No network” on the Service screen and "
                    + "try again — the second failure is transient and must not be "
                    + "treated the same way.")
            }
            .disabledWhileBusy(model.isBusy)
        }
    }

    // MARK: - Seeded accounts

    private var accountList: some View {
        SectionCard(
            title: "Keys this service knows",
            subtitle: "The stand-in fulfilment backend's database. In production "
                + "this is Gumroad, Polar, or your own API — and this table is a "
                + "vendor dashboard you would never ship."
        ) {
            VStack(spacing: 0) {
                ForEach(model.accounts) { account in
                    AccountRow(account: account, model: model)
                    if account.id != model.accounts.last?.id {
                        Divider().padding(.vertical, 8)
                    }
                }
            }
        }
    }

    // MARK: - Provider capabilities

    private var capabilities: some View {
        SectionCard(
            title: "What this provider can do",
            subtitle: "Read these before drawing buttons. A provider that cannot "
                + "release seats should not have a Deactivate button — the runtime "
                + "checks the same flags before it tries."
        ) {
            let capabilities = model.runtime.providers.first?.capabilities ?? []
            VStack(alignment: .leading, spacing: 6) {
                CapabilityRow("Activation", capabilities.contains(.activation))
                CapabilityRow("Deactivation (seat release)", capabilities.contains(.deactivation))
                CapabilityRow("Refresh", capabilities.contains(.refresh))
                CapabilityRow("Remote validation", capabilities.contains(.remoteValidation))
                CapabilityRow("Seat accounting", capabilities.contains(.seatAccounting))
                CapabilityRow("Returns signed licenses", capabilities.contains(.signedLicenses))
            }
        }
    }
}

// MARK: - Rows

private struct CapabilityRow: View {
    let title: String
    let supported: Bool

    init(_ title: String, _ supported: Bool) {
        self.title = title
        self.supported = supported
    }

    var body: some View {
        Label {
            Text(title).font(.callout)
        } icon: {
            Image(systemName: supported ? "checkmark.circle.fill" : "slash.circle")
                .foregroundStyle(supported ? .green : .secondary)
        }
    }
}

private struct AccountRow: View {
    let account: DemoStoreBackend.Account
    let model: LicensingModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(account.title).font(.callout.weight(.medium))
                    StatusTag(status: account.status)
                }
                Text(account.key)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(account.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(seatSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                Button("Use") { model.keyEntry = account.key }
                    .controlSize(.small)
                Button("Activate") {
                    model.keyEntry = account.key
                    Task { await model.activate() }
                }
                .controlSize(.small)
                .disabledWhileBusy(model.isBusy)
            }
        }
    }

    private var seatSummary: String {
        let limit = account.seatLimit.map(String.init) ?? "∞"
        var parts = ["seats \(account.seatsUsed)/\(limit)"]
        if let expiry = account.providerExpiresAt {
            parts.append("renews \(DemoFormat.expiry(expiry, now: model.clock.now))")
        } else {
            parts.append("never expires")
        }
        return parts.joined(separator: "  ·  ")
    }
}

struct StatusTag: View {
    let status: ProviderStateSnapshot.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .active: return .green
        case .lapsed: return .orange
        case .revoked: return .red
        default: return .secondary
        }
    }
}
