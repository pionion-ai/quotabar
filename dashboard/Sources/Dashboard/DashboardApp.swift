import SwiftUI

@main
struct DashboardApp: App {
    private static let defaultThresholdPercent: Double = 85

    @StateObject private var store: UsageStore
    @State private var thresholdEnabled: Bool
    @State private var thresholdValue: Double

    init() {
        let settings = Settings.load()
        let store = UsageStore(provider: UsageClient.live(), threshold: settings.threshold)
        store.onAlerts = { Notifier.post($0) }
        Notifier.requestAuthorization()
        store.start()
        _store = StateObject(wrappedValue: store)
        _thresholdEnabled = State(initialValue: settings.threshold != nil)
        _thresholdValue = State(initialValue: settings.threshold ?? Self.defaultThresholdPercent)
    }

    var body: some Scene {
        MenuBarExtra {
            GaugesView(
                store: store,
                now: store.currentTime,
                thresholdEnabled: $thresholdEnabled,
                thresholdValue: $thresholdValue,
                onThresholdChange: applyThreshold,
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
}
