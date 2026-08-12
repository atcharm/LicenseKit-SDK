import DemoBackstage
import LicenseKit
import SwiftUI

/// Signed license files: the offline path, and every way it can fail.
///
/// Each row is a situation a real support queue produces, minted on demand by the
/// vendor tooling in `DemoBackstage`. Installing them in order is the fastest way
/// to see what each built-in rule actually does — and the tampered and untrusted
/// rows are worth running at least once, because they are the attacks the
/// signature exists to stop.
struct LicenseFilesScreen: View {
    @Bindable var model: LicensingModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                scenarios
                pasteBox
                importBox
            }
            .padding(20)
        }
    }

    private var intro: some View {
        SectionCard(
            title: "Offline licenses",
            subtitle: "No server, no network, no seats. A file the customer "
                + "downloads, verified against a public key compiled into the app."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Callout(text: "A license that fails validation is never persisted, and "
                    + "install throws instead. Storing one the app rejects on every "
                    + "launch would produce a permanently broken install with no way out.")

                if !model.runtime.setup.configuresSealingKey {
                    Callout(
                        kind: .warning,
                        text: "The sealing key is switched off in Setup, so the "
                            + "encrypted row will fail to open. That is the correct "
                            + "behaviour for an app that ships no symmetric key."
                    )
                }

                if model.runtime.setup.signaturePolicy == .disabled {
                    Callout(
                        kind: .danger,
                        text: "Signature checking is disabled in Setup. The tampered "
                            + "and untrusted-issuer rows will now install cleanly, "
                            + "which is exactly why you should never ship this."
                    )
                }

                if model.runtime.setup.validatorPreset == .connected {
                    // A real trap, not a demo artefact: the subscription files carry
                    // a 30-day offline grace, and a file has no provider to refresh
                    // against. Under the connected chain they eventually fail a rule
                    // that cannot be cured.
                    Callout(
                        kind: .warning,
                        text: "The rule chain is connectedDefault(), which includes the "
                            + "offline-staleness check. The subscription rows carry a "
                            + "30-day offline grace and have no provider to refresh "
                            + "against, so travelling more than 30 days forward will "
                            + "fail them with offlineGraceExhausted. Switch to "
                            + "offlineDefault() in Setup — that is the chain that "
                            + "belongs with file-delivered licenses."
                    )
                }
            }
        }
    }

    private var scenarios: some View {
        SectionCard(
            title: "Twelve licenses, minted on demand",
            subtitle: "Install one, then look at the Status screen's validation report."
        ) {
            VStack(spacing: 0) {
                ForEach(OfflineScenario.allCases) { scenario in
                    ScenarioRow(scenario: scenario, model: model)
                    if scenario != OfflineScenario.allCases.last {
                        Divider().padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private var pasteBox: some View {
        SectionCard(
            title: "Install pasted text",
            subtitle: "The base64 form, as a customer receives it by email. The "
                + "reader tolerates the line wrapping and stray whitespace a mail "
                + "client introduces, so pasting straight from a message works."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $model.pastedLicense)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(.quaternary)
                    )

                HStack(spacing: 10) {
                    Button("Install pasted license") {
                        Task { await model.installPastedLicense() }
                    }
                    Button("Paste from clipboard") {
                        if let text = DemoPasteboard.paste() {
                            model.pastedLicense = text
                        }
                    }
                    Button("Clear") { model.pastedLicense = "" }
                        .disabled(model.pastedLicense.isEmpty)
                }
                .disabledWhileBusy(model.isBusy)
            }
        }
    }

    private var importBox: some View {
        SectionCard(
            title: "Install from a file",
            subtitle: "read(contentsOf:) accepts the binary container or its base64 "
                + "text form, so a customer who saved the email body as a file is "
                + "still fine."
        ) {
            Button("Choose a license file…") {
                guard let url = DemoFilePanels.open() else { return }
                Task { await model.installFile(at: url) }
            }
            .disabledWhileBusy(model.isBusy)
        }
    }
}

// MARK: - Scenario row

private struct ScenarioRow: View {
    let scenario: OfflineScenario
    let model: LicensingModel

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(scenario.title).font(.callout.weight(.medium))
                    if scenario.isSealed {
                        Label("sealed", systemImage: "lock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(scenario.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(scenario.expectation, systemImage: "arrow.turn.down.right")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Install") {
                    Task { await model.install(scenario) }
                }
                .controlSize(.small)

                if scenario == .bundle {
                    Button("Install first seat") {
                        Task { await model.installFirstFromBundle() }
                    }
                    .controlSize(.small)
                }

                Menu("More") {
                    Button(copied ? "Copied" : "Copy as text") {
                        guard let text = model.text(for: scenario) else { return }
                        DemoPasteboard.copy(text)
                        model.pastedLicense = text
                        copied = true
                    }
                    Button("Save file…") {
                        guard let data = model.fileData(for: scenario) else { return }
                        _ = DemoFilePanels.save(
                            data,
                            suggestedName: model.suggestedFilename(for: scenario)
                        )
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
            }
            .disabledWhileBusy(model.isBusy)
        }
    }
}
