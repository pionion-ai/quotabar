import SwiftUI

@main
struct DashboardApp: App {
    @StateObject private var store: UsageStore
    @State private var thresholdEnabled: Bool
    @State private var thresholdValue: Double
    @State private var now = Date()

    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init() {
        let settings = Settings.load()
        let store = UsageStore(provider: UsageClient.live(), threshold: settings.threshold)
        store.onAlerts = { Notifier.post($0) }
        _store = StateObject(wrappedValue: store)
        _thresholdEnabled = State(initialValue: settings.threshold != nil)
        _thresholdValue = State(initialValue: settings.threshold ?? 85)
    }

    var body: some Scene {
        MenuBarExtra {
            GaugesView(
                store: store,
                now: now,
                thresholdEnabled: $thresholdEnabled,
                thresholdValue: $thresholdValue,
                onThresholdChange: applyThreshold,
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .onReceive(refreshTimer) { _ in Task { await store.refresh() } }
            .onReceive(tickTimer) { now = $0 }
            .task {
                Notifier.requestAuthorization()
                await store.refresh()
            }
        } label: {
            Text(store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    private func applyThreshold() {
        let value: Double? = thresholdEnabled ? thresholdValue : nil
        store.setThreshold(value)
        Settings(threshold: value).save()
    }
}
