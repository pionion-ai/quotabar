import SwiftUI

@main
struct DashboardApp: App {
    private static let defaultThresholdPercent: Double = 85

    @StateObject private var store: UsageStore
    @State private var thresholdEnabled: Bool
    @State private var thresholdValue: Double
    @State private var launchAtLogin: Bool

    init() {
        let settings = Settings.load()
        let store = UsageStore(provider: UsageClient.live(), threshold: settings.threshold)
        store.onAlerts = { Notifier.post($0) }
        Notifier.requestAuthorization()
        store.start()
        _store = StateObject(wrappedValue: store)
        _thresholdEnabled = State(initialValue: settings.threshold != nil)
        _thresholdValue = State(initialValue: settings.threshold ?? Self.defaultThresholdPercent)
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
    }

    var body: some Scene {
        MenuBarExtra {
            GaugesView(
                store: store,
                now: store.currentTime,
                thresholdEnabled: $thresholdEnabled,
                thresholdValue: $thresholdValue,
                launchAtLogin: $launchAtLogin,
                onThresholdChange: applyThreshold,
                onLaunchAtLoginChange: applyLaunchAtLogin,
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            Text(store.menuBarTitle)
                .foregroundStyle(menuBarColor(store.menuBarColor))
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarColor(_ c: GaugeColor) -> Color {
        switch c { case .green: return .green; case .amber: return .orange; case .red: return .red }
    }

    private func applyThreshold() {
        let value: Double? = thresholdEnabled ? thresholdValue : nil
        store.setThreshold(value)
        Settings(threshold: value).save()
    }

    private func applyLaunchAtLogin() {
        do { try LoginItem.setEnabled(launchAtLogin) }
        catch {
            // revert the toggle to the real state if the system call failed
            launchAtLogin = LoginItem.isEnabled
        }
    }
}
