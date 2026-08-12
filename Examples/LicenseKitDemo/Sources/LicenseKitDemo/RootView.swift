import LicenseKit
import SwiftUI

/// The demo's shell: a sidebar of screens, and a header that always shows the
/// current licensing state, whether something is in flight, and how the last
/// operation ended.
///
/// Keeping those three things permanently visible is a deliberate choice. The
/// most common mistake in a licensing UI is showing state only on the screen that
/// changed it, so the user cannot tell whether the app now considers them
/// licensed.
struct RootView: View {
    @Bindable var model: LicensingModel
    @State private var screen: Screen? = .status

    enum Screen: String, CaseIterable, Identifiable, Hashable {
        case status, activate, files, features, service, setup, activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .status: return "Status"
            case .activate: return "Activate"
            case .files: return "License files"
            case .features: return "Features"
            case .service: return "Service"
            case .setup: return "Setup"
            case .activity: return "Activity"
            }
        }

        var symbol: String {
            switch self {
            case .status: return "seal"
            case .activate: return "key"
            case .files: return "doc.badge.gearshape"
            case .features: return "square.grid.2x2"
            case .service: return "server.rack"
            case .setup: return "slider.horizontal.3"
            case .activity: return "list.bullet.rectangle"
            }
        }

        var caption: String {
            switch self {
            case .status: return "What the SDK currently believes"
            case .activate: return "Redeem a key against a provider"
            case .files: return "Signed licenses, and how they fail"
            case .features: return "Entitlement gates, live"
            case .service: return "Make the backend misbehave"
            case .setup: return "The configuration, rebuilt live"
            case .activity: return "SDK, service, and app diagnostics"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { item in
                NavigationLink(value: item) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                            Text(item.caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: item.symbol)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter(model: model)
            }
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .navigationTitle("Aperture")
    }

    @ViewBuilder
    private var detail: some View {
        switch screen ?? .status {
        case .status: StatusScreen(model: model)
        case .activate: ActivateScreen(model: model)
        case .files: LicenseFilesScreen(model: model)
        case .features: FeaturesScreen(model: model)
        case .service: ServiceScreen(model: model)
        case .setup: SetupScreen(model: model)
        case .activity: ActivityScreen(model: model)
        }
    }

    /// State, progress, and the last outcome — visible from every screen.
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                StatePill(state: model.state)

                Text(model.state.localizedSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if model.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.busyLabel).font(.callout).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }

            if let outcome = model.outcome {
                OutcomeBanner(outcome: outcome)
                    .id(outcome.id)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .animation(.default, value: model.isBusy)
        .animation(.default, value: model.outcome?.id)
    }
}

/// A compact readout of the running configuration, so the sidebar always answers
/// "which setup produced this?".
private struct SidebarFooter: View {
    let model: LicensingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Running configuration")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(model.runtime.setup.validatorPreset.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("signatures: \(model.runtime.setup.signaturePolicy.title.lowercased())")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("store: \(model.runtime.setup.storeKind.title.lowercased())")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.clock.offset != 0 {
                Label(
                    "clock \(model.clock.offset > 0 ? "+" : "−")"
                        + DemoFormat.duration(model.clock.offset),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
