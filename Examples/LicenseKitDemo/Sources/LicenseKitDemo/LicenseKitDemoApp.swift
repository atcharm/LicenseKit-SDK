import AppKit
import DemoBackstage
import SwiftUI

/// Aperture — a worked example of integrating LicenseKit.
///
/// The app is a real client: it links `LicenseKit` and calls nothing but the
/// public API. Everything that stands in for a vendor's infrastructure — the
/// signing key, the license factory, the licensing service — lives in
/// `DemoBackstage`, which in production would be code running on a server you
/// control.
///
/// Start with `DemoRuntime.make(setup:…)`. That function is the whole integration;
/// the rest is user interface for poking at it.
@main
struct LicenseKitDemoApp: App {
    @NSApplicationDelegateAdaptor(DemoAppDelegate.self) private var delegate

    /// One model for the whole app. Licensing state is global to a process, and
    /// pretending otherwise leads to two views disagreeing about whether the user
    /// has paid.
    @State private var model = LicensingModel()

    var body: some Scene {
        Window("Aperture — LicenseKit Demo", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1_040, minHeight: 680)
                .task {
                    // `begin()` is idempotent-ish by way of `LicenseManager.start()`,
                    // which is safe to call again; `.task` runs once per window.
                    await model.begin()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Makes a SwiftPM executable behave like an app.
///
/// A target built with `swift build` is a plain binary rather than an `.app`
/// bundle, so it launches as an accessory with no Dock presence and no keyboard
/// focus. Two lines fix it. Nothing here is required in a real Xcode app — it is
/// the price of keeping this demo runnable with `swift run`.
@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
