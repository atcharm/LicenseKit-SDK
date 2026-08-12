import LicenseKit
import SwiftUI

/// Everything the SDK currently believes, and why.
///
/// The rule-by-rule report at the bottom is the part worth stealing. When a
/// customer writes in saying "it says my license is invalid", `ValidationReport`
/// already contains the answer — which rule failed, which had nothing to check,
/// and which passed with a warning. Rendering it costs one view and removes most
/// licensing support tickets.
struct StatusScreen: View {
    let model: LicensingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                actions

                if let record = model.state.record, let report = model.state.report {
                    if !report.failures.isEmpty {
                        failures(report)
                    }
                    if !report.warnings.isEmpty {
                        warnings(report)
                    }
                    licenseDetail(record)
                    entitlements(record)
                    reportCard(report)
                    if !record.license.metadata.isEmpty {
                        metadata(record)
                    }
                } else {
                    unlicensed
                }

                configuration
            }
            .padding(20)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        SectionCard(
            title: "Operations",
            subtitle: "Revalidate re-runs the rules locally. Refresh asks the "
                + "provider. Deactivate releases this Mac's seat; Remove forgets "
                + "the license without telling anyone."
        ) {
            HStack(spacing: 10) {
                Button("Revalidate") {
                    Task { await model.revalidate() }
                }

                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .disabled(model.state.record == nil)

                Spacer()

                Button("Deactivate") {
                    Task { await model.deactivate() }
                }
                // Only offered when the provider behind this record actually has a
                // seat-release endpoint. Gumroad, for instance, does not.
                .disabled(!model.canDeactivate)
                .help(model.canDeactivate
                    ? "Releases the seat, then removes the local record."
                    : "This provider does not support releasing seats.")

                Button("Remove locally", role: .destructive) {
                    Task { await model.removeLicense() }
                }
                .disabled(model.state.record == nil)
            }
            .disabledWhileBusy(model.isBusy)
        }
    }

    // MARK: - Verdict

    private func failures(_ report: ValidationReport) -> some View {
        SectionCard(
            title: "Why it was rejected",
            subtitle: "Every rule ran, so this is the complete list rather than "
                + "just the first problem. Each failure has a different right answer."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                    let remedy = Remedy(for: failure)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: remedy.symbol)
                            .foregroundStyle(.red)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(failure.description)
                                .font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(remedy.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let rule = report.rule(for: failure) {
                                Text("rule: \(rule.rawValue)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func warnings(_ report: ValidationReport) -> some View {
        SectionCard(
            title: "Valid, but worth saying",
            subtitle: report.isRunningOnGrace
                ? "A grace period is the only reason this license still works. "
                    + "That deserves a persistent banner, not silence."
                : "Warnings never block the app. They exist so an imminent expiry "
                    + "is not a surprise."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning.description, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - The record

    private func licenseDetail(_ record: LicenseRecord) -> some View {
        let now = model.clock.now
        let policy = record.license.policy

        return SectionCard(
            title: "Installed license",
            subtitle: "The signed claim set is immutable. Everything under "
                + "“Provider state” is local, unsigned, and free to change — which "
                + "is how a renewal happens without reissuing anything."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                DetailRow(label: "Product", value: "\(record.license.product.id)")
                if let edition = record.license.product.edition {
                    DetailRow(label: "Edition", value: edition)
                }
                DetailRow(label: "License ID", value: record.license.id.rawValue)
                // Redacted, always. License keys are bearer credentials — never
                // put the raw value anywhere you do not fully control.
                DetailRow(label: "Key", value: record.license.key.redacted)
                DetailRow(label: "Kind", value: policy.kind.rawValue)
                DetailRow(label: "Issuer", value: record.license.issuance.issuer)
                DetailRow(label: "Issued", value: DemoFormat.timestamp(record.license.issuance.issuedAt))

                Divider().padding(.vertical, 4)

                DetailRow(label: "Starts", value: policy.validity.notBefore.map(DemoFormat.timestamp) ?? "immediately")
                DetailRow(label: "Signed term ends", value: policy.validity.expiresAt.map(DemoFormat.timestamp) ?? "never")
                DetailRow(
                    label: "Effective expiry",
                    value: DemoFormat.expiry(record.effectiveExpiry, now: now)
                )
                if let grace = policy.expiryGraceInterval {
                    DetailRow(label: "Expiry grace", value: DemoFormat.duration(grace))
                }
                if let grace = policy.offlineGraceInterval {
                    DetailRow(label: "Offline grace", value: DemoFormat.duration(grace))
                }
                if let bound = policy.versionBound {
                    DetailRow(label: "Version ceiling", value: "up to \(bound.maximumVersion)")
                }
                DetailRow(label: "Seats", value: DemoFormat.seats(record))

                Divider().padding(.vertical, 4)

                DetailRow(label: "Customer", value: record.license.subject.name ?? "anonymous", mono: false)
                if let email = record.license.subject.email {
                    DetailRow(label: "Email", value: email)
                }
                if let organization = record.license.subject.organization {
                    DetailRow(label: "Organisation", value: organization, mono: false)
                }

                Divider().padding(.vertical, 4)

                DetailRow(
                    label: "Signature",
                    value: record.signature.map { "\($0.algorithm.rawValue), key '\($0.keyID)'" }
                        ?? "none — this license is unsigned"
                )
                DetailRow(label: "Origin", value: "\(record.origin.provider) via \(record.origin.medium.rawValue)")
                DetailRow(label: "Retrieved", value: DemoFormat.timestamp(record.origin.retrievedAt))

                Divider().padding(.vertical, 4)

                DetailRow(label: "Provider status", value: record.providerState.status.rawValue)
                DetailRow(
                    label: "Provider expiry",
                    value: record.providerState.expiresAt.map { DemoFormat.expiry($0, now: now) }
                        ?? "not asserted"
                )
                DetailRow(
                    label: "Last validated",
                    value: record.lastValidatedAt.map {
                        "\(DemoFormat.timestamp($0)) — \(DemoFormat.duration(now.timeIntervalSince($0))) ago"
                    } ?? "never"
                )
                if let activation = record.activation {
                    DetailRow(label: "Activated on", value: activation.deviceName ?? "this Mac", mono: false)
                    // Salted and hashed, so it can be sent to a provider for seat
                    // accounting without disclosing a hardware identifier.
                    DetailRow(label: "Fingerprint", value: activation.fingerprint.rawValue)
                }
            }
        }
    }

    private func entitlements(_ record: LicenseRecord) -> some View {
        SectionCard(
            title: "Granted entitlements",
            subtitle: "What the license actually unlocks. Note these are "
                + "capabilities, not tiers — the Features screen gates on exactly "
                + "these identifiers."
        ) {
            if record.license.entitlements.isEmpty {
                Text("None. A valid license that grants nothing is legal, and "
                    + "means every gate stays closed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(record.license.entitlements.sorted, id: \.id) { entitlement in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(entitlement.id.rawValue)
                                .font(.system(.callout, design: .monospaced))
                            if let limit = entitlement.limit {
                                Text("limit \(limit)")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func reportCard(_ report: ValidationReport) -> some View {
        SectionCard(
            title: "Validation report",
            subtitle: "Evaluated \(DemoFormat.timestamp(report.evaluatedAt)) against "
                + "\(report.evaluations.count) rules. “Nothing to check” is recorded "
                + "distinctly from “passed”, so a report never implies a check ran "
                + "when it did not."
        ) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(report.evaluations.enumerated()), id: \.offset) { _, evaluation in
                    RuleRow(evaluation: evaluation)
                }
            }
        }
    }

    private func metadata(_ record: LicenseRecord) -> some View {
        SectionCard(
            title: "Metadata",
            subtitle: "Free-form fields carried inside the signed payload, so they "
                + "cannot be edited after issuance."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.license.metadata.keys.sorted(), id: \.self) { key in
                    if let value = record.license.metadata[key] {
                        DetailRow(label: key, value: value.display)
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var unlicensed: some View {
        SectionCard(
            title: "No license installed",
            subtitle: "This is the state a fresh install starts in, and the one to "
                + "design first — it is what every user sees before they pay."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Callout(text: "There are two ways in. Activate redeems a key against "
                    + "the provider. License files install a signed file, which needs "
                    + "no network at all.")
                Text("start() looked in \(model.runtime.storeDescription) and found "
                    + "nothing. Note it did not throw — a launch path has to produce "
                    + "some state, and an app that crashes on a corrupt licensing "
                    + "store is worse than one that offers a re-activation button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Running configuration

    private var configuration: some View {
        SectionCard(
            title: "What this build is checking",
            subtitle: "The rule chain currently configured, in the order it runs."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.runtime.activeRules.map(\.rawValue).joined(separator: " → "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DetailRow(label: "Store", value: model.runtime.storeDescription)
                DetailRow(
                    label: "App version",
                    value: model.runtime.resolvedApplicationVersion.map(String.init(describing:))
                        ?? "unset — VersionBoundRule cannot run"
                )
                DetailRow(
                    label: "Clock offset",
                    value: model.clock.offset == 0
                        ? "none (system time)"
                        : "\(model.clock.offset > 0 ? "+" : "−")\(DemoFormat.duration(model.clock.offset))"
                )

                if model.clock.offset != 0 {
                    Callout(
                        kind: .warning,
                        text: "The clock is shifted, so “now” is "
                            + "\(DemoFormat.timestamp(model.clock.now)) as far as every "
                            + "rule is concerned."
                    )
                }
            }
        }
    }
}
