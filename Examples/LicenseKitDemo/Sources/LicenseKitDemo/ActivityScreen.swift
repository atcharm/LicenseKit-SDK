import LicenseKit
import SwiftUI

/// Diagnostics from the SDK, the service, and the app, interleaved.
///
/// The SDK writes to no log of its own — `LicenseKitConfiguration.log` is the only
/// outlet, and it receives nothing but redacted strings, because license keys are
/// bearer credentials and subjects are personal data. Where those messages go is
/// the host's decision; here they go to a list.
///
/// Reading the three sources side by side is the point. A retry is the SDK's
/// doing; a 503 is the service's; "Activation…" is the user's.
struct ActivityScreen: View {
    let model: LicensingModel

    @State private var sources: Set<ActivityEntry.Source> = Set(ActivityEntry.Source.allCases)
    @State private var minimumLevel: LicenseLogLevel = .debug

    private var entries: [ActivityEntry] {
        model.activity
            .filter { sources.contains($0.source) }
            .filter { $0.level >= minimumLevel }
            .reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing logged yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Activate a key or install a license file.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            ActivityRow(entry: entry)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ForEach(ActivityEntry.Source.allCases) { source in
                Toggle(source.title, isOn: Binding(
                    get: { sources.contains(source) },
                    set: { isOn in
                        if isOn { sources.insert(source) } else { sources.remove(source) }
                    }
                ))
                .toggleStyle(.checkbox)
            }

            Divider().frame(height: 16)

            Picker("Level", selection: $minimumLevel) {
                Text("All").tag(LicenseLogLevel.debug)
                Text("Info").tag(LicenseLogLevel.info)
                Text("Notice").tag(LicenseLogLevel.notice)
                Text("Errors").tag(LicenseLogLevel.error)
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            Text("\(entries.count) shown")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Copy") {
                DemoPasteboard.copy(
                    entries.reversed()
                        .map { "\(DemoFormat.time($0.at))  [\($0.source.title)]  \($0.message)" }
                        .joined(separator: "\n")
                )
            }
            .controlSize(.small)

            Button("Clear") { model.clearActivity() }
                .controlSize(.small)
                .disabled(model.activity.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(DemoFormat.time(entry.at))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .leading)

            Text(entry.source.title)
                .font(.caption2.weight(.semibold))
                .frame(width: 54, alignment: .leading)
                .foregroundStyle(sourceTint)

            Text(entry.message)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(entry.level.tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
    }

    private var sourceTint: Color {
        switch entry.source {
        case .sdk: return .accentColor
        case .service: return .purple
        case .app: return .teal
        }
    }
}
