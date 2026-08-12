import LicenseKit
import SwiftUI

/// The configuration, editable at runtime.
///
/// In a shipping app nearly everything here is decided once and compiled in — a
/// single call to `LicenseKitConfiguration(…)`. It is exposed live because the
/// choices *are* the integration, and the fastest way to understand a rule is to
/// switch it off and watch the same license change verdict.
///
/// Time travel sits at the bottom and applies immediately, because every date
/// decision in the SDK routes through `LicenseClock` rather than calling `Date()`.
struct SetupScreen: View {
    @Bindable var model: LicensingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pending
                clock
                storage
                verification
                rules
                identity
                refresh
            }
            .padding(20)
        }
    }

    // MARK: - Apply / revert

    private var pending: some View {
        SectionCard(
            title: "Rebuild the licensing layer",
            subtitle: "Changes below are staged. Applying them constructs a fresh "
                + "LicenseManager and re-reads the store, so the same license is "
                + "re-validated under the new rules."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("Apply") {
                        Task { await model.applySetup() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasPendingSetupChanges)

                    Button("Revert") { model.revertSetup() }
                        .disabled(!model.hasPendingSetupChanges)

                    if model.hasPendingSetupChanges {
                        Label("unapplied changes", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .disabledWhileBusy(model.isBusy)

                if !model.runtime.notes.isEmpty {
                    ForEach(model.runtime.notes, id: \.self) { note in
                        Callout(kind: .warning, text: note)
                    }
                }
            }
        }
    }

    // MARK: - Clock

    private var clock: some View {
        SectionCard(
            title: "Time travel",
            subtitle: "Applies immediately and re-runs the rules. This is how to "
                + "watch a subscription cross into its warning window, then its grace "
                + "period, then expiry — without waiting."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("+1 day") { Task { await model.travel(days: 1) } }
                    Button("+7 days") { Task { await model.travel(days: 7) } }
                    Button("+30 days") { Task { await model.travel(days: 30) } }
                    Button("+1 year") { Task { await model.travel(days: 365) } }
                    Divider().frame(height: 16)
                    Button("−30 days") { Task { await model.travel(days: -30) } }
                        .help("Winding the clock back is the cheapest attack on a "
                            + "time-limited license. ClockTamperRule notices.")
                    Button("Reset") { Task { await model.resetClock() } }
                }
                .controlSize(.small)
                .disabledWhileBusy(model.isBusy)

                DetailRow(label: "Offset", value: DemoFormat.offset(model.clock.offset))
                DetailRow(label: "The SDK thinks it is", value: DemoFormat.timestamp(model.clock.now))

                if model.clock.offset < -.licenseDays(1), model.runtime.setup.detectsClockTampering {
                    Callout(
                        kind: .warning,
                        text: "The clock is more than a day behind the furthest-forward "
                            + "time the SDK has recorded, so ClockTamperRule will fail. "
                            + "The one-day tolerance absorbs an NTP correction or a dead "
                            + "coin cell without punishing honest users."
                    )
                }
            }
        }
    }

    // MARK: - Storage

    private var storage: some View {
        SectionCard(
            title: "Where records are kept",
            subtitle: "Records are stored as plain JSON on purpose: they are derived "
                + "from a license the user already holds, and the signature — not the "
                + "storage format — is what stops a forged record being honoured."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Store", selection: $model.draftSetup.storeKind) {
                    ForEach(DemoSetup.StoreKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.draftSetup.storeKind.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DetailRow(label: "Currently", value: model.runtime.storeDescription)

                Callout(text: "Install a license, quit, and relaunch to see the file "
                    + "store restore it. The in-memory store will not, which is the "
                    + "correct behaviour for an app that re-activates every launch.")
            }
        }
    }

    // MARK: - Verification

    private var verification: some View {
        SectionCard(
            title: "Signature policy",
            subtitle: "The trust anchor. Everything else is defence in depth; this is "
                + "the part that establishes a vendor actually issued the license."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Signatures", selection: $model.draftSetup.signaturePolicy) {
                    ForEach(DemoSetup.SignaturePolicyChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.draftSetup.signaturePolicy.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.draftSetup.signaturePolicy == .disabled {
                    Callout(
                        kind: .danger,
                        text: "With this applied, a tampered license installs cleanly. "
                            + "Removing the signature rule is the one customisation that "
                            + "is never defensible in a shipping build."
                    )
                }

                Divider()

                Toggle("Configure the sealing key on the file reader",
                       isOn: $model.draftSetup.configuresSealingKey)
                Text("Sealing gives a license file confidentiality and makes casual "
                    + "editing fail loudly. It is not what makes a license "
                    + "trustworthy — an app that opens sealed files must carry the key, "
                    + "and anything in a binary can be extracted. Licenses are signed "
                    + "first and sealed second precisely so authenticity survives that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rules

    private var rules: some View {
        SectionCard(
            title: "The rule chain",
            subtitle: "Which checks run on every validation, including every feature gate."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Preset", selection: $model.draftSetup.validatorPreset) {
                    ForEach(DemoSetup.ValidatorPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.draftSetup.validatorPreset.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Enforce machine binding", isOn: $model.draftSetup.enforcesMachineBinding)
                Toggle("Enforce the seat ceiling", isOn: $model.draftSetup.enforcesSeatLimit)
                Toggle("Detect clock rollback", isOn: $model.draftSetup.detectsClockTampering)

                Text("Removing machine binding and the seat limit is legitimate for a "
                    + "floating or site license. Removing the signature rule is not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Add a custom rule the demo licenses fail",
                       isOn: $model.draftSetup.enforcesSiteDomainRule)
                Text("A ClosureRule requiring an @acme.example subject. Every license "
                    + "here is issued to @northlight.example, so applying it rejects "
                    + "them all — which is the point: it shows how a host-supplied rule "
                    + "and a custom failure reason surface in the report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Text("Expiry warning threshold")
                    Spacer()
                    Text("\(Int(model.draftSetup.expiryWarningDays)) days")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.draftSetup.expiryWarningDays, in: 1...60, step: 1)

                DetailRow(
                    label: "Running now",
                    value: model.runtime.activeRules.map(\.rawValue).joined(separator: ", ")
                )
            }
        }
    }

    // MARK: - Identity and version

    private var identity: some View {
        SectionCard(
            title: "This device, and this build",
            subtitle: "What the fingerprint and version rules have to work with."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Report the real fingerprint for this Mac",
                       isOn: $model.draftSetup.identifiesAsThisMac)
                Text("Switch it off to impersonate a different machine. A license "
                    + "activated here then fails MachineBindingRule with "
                    + "machineMismatch — the same thing a customer sees after copying "
                    + "an app and its licensing state to another Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Persist the clock high-water mark", isOn: $model.draftSetup.persistsTimeAnchor)
                Text("On, the rollback anchor lives in UserDefaults and survives "
                    + "relaunch. Off, it is in memory only and detects tampering within "
                    + "one session. Either is defeatable by clearing app state — an "
                    + "accepted trade, since the alternative punishes users whose clock "
                    + "is merely wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Text("Application version")
                    TextField("2.0.0", text: $model.draftSetup.applicationVersion)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120)
                }
                Text("VersionBoundRule compares this against the license's ceiling. "
                    + "Install “Perpetual fallback, up to 1.9.0” and set this to 2.0.0 "
                    + "to fail the bound, then 1.8.0 to pass it. A real app reads "
                    + "CFBundleShortVersionString automatically; this demo has no "
                    + "bundle, so leaving the field empty makes the rule inapplicable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DetailRow(
                    label: "Resolved",
                    value: model.runtime.resolvedApplicationVersion.map(String.init(describing:))
                        ?? "unset — the rule cannot run"
                )
            }
        }
    }

    // MARK: - Refresh

    private var refresh: some View {
        SectionCard(
            title: "Refresh policy",
            subtitle: "When the runtime reaches for a provider on its own."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Refresh on start", isOn: $model.draftSetup.refreshesOnStart)

                HStack {
                    Text("Minimum interval between provider calls")
                    Spacer()
                    Text(model.draftSetup.minimumRefreshInterval == 0
                        ? "none"
                        : DemoFormat.duration(model.draftSetup.minimumRefreshInterval))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $model.draftSetup.minimumRefreshInterval,
                    in: 0...(.licenseHours(12)),
                    step: .licenseHours(1)
                )
                Text("Zero here so the demo can refresh repeatedly. A real app wants "
                    + "hours, to stop a chatty client making a licensing request on "
                    + "every window activation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Text("Eager refresh window before expiry")
                    Spacer()
                    Text("\(Int(model.draftSetup.eagerRefreshDays)) days")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.draftSetup.eagerRefreshDays, in: 0...14, step: 1)
                Text("Inside this window the rate limit is ignored. It is what "
                    + "prevents “I paid yesterday and it still says expired”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Stepper(
                    "Retries after a transient failure: \(model.draftSetup.maximumRetries)",
                    value: $model.draftSetup.maximumRetries,
                    in: 0...5
                )
                Text("Only transient failures are retried. A rejected license is a "
                    + "settled answer, and hammering the service with it would waste "
                    + "the user's battery and the vendor's rate limit with no chance of "
                    + "a different result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
