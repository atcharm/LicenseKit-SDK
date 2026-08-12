import AppKit
import LicenseKit
import SwiftUI

// MARK: - Status

/// The current licensing state, in one glance.
struct StatePill: View {
    let state: LicenseState

    var body: some View {
        let appearance = state.appearance
        return Label(appearance.title, systemImage: appearance.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(appearance.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(appearance.tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Layout

/// A titled group with an optional explanatory subtitle.
struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A label/value pair, monospaced on the value so identifiers line up.
struct DetailRow: View {
    let label: String
    let value: String
    var mono = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An inline note explaining *why* something behaves the way it does.
struct Callout: View {
    enum Kind {
        case note, warning, danger

        var symbol: String {
            switch self {
            case .note: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .danger: return "exclamationmark.octagon"
            }
        }

        var tint: Color {
            switch self {
            case .note: return .accentColor
            case .warning: return .orange
            case .danger: return .red
            }
        }
    }

    var kind: Kind = .note
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Outcomes

/// The result of the last operation: what happened, and what to do about it.
struct OutcomeBanner: View {
    let outcome: DemoOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.symbol)
                .foregroundStyle(outcome.tint)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(outcome.title).font(.callout.weight(.semibold))
                if !outcome.message.isEmpty {
                    Text(outcome.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let hint = outcome.hint {
                    Label(hint, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(outcome.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(outcome.tint.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Validation report

/// One rule's verdict.
struct RuleRow: View {
    let evaluation: RuleEvaluation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: evaluation.outcome.symbol)
                .foregroundStyle(evaluation.outcome.tint)
                .frame(width: 14)
            Text(evaluation.rule.rawValue)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text(evaluation.outcome.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - System integration
//
// A SwiftPM executable is not an app bundle, so these use AppKit directly rather
// than SwiftUI's document-based importers, which expect one.

enum DemoPasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func paste() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

enum DemoFilePanels {
    @MainActor
    static func save(_ data: Data, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    static func open() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Small helpers

extension LicenseLogLevel {
    var tint: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .primary
        case .notice: return .orange
        case .error: return .red
        }
    }
}

extension View {
    /// Dims and disables a view while a licensing call is in flight.
    func disabledWhileBusy(_ isBusy: Bool) -> some View {
        disabled(isBusy).opacity(isBusy ? 0.55 : 1)
    }
}
