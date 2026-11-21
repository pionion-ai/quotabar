import SwiftUI

@main
struct DashboardApp: App {
    private static let defaultThresholdPercent: Double = 85

    @StateObject private var coordinator: DashboardCoordinator
    @State private var thresholdEnabled: Bool
    @State private var thresholdValue: Double
    @State private var launchAtLogin: Bool

    init() {
        let settings = Settings.load()
        let enabled = Set(Flavor.providerIDs(appStore: Flavor.isAppStore))

        let claudeStore = UsageStore(provider: UsageClient.live(), threshold: settings.threshold)
        claudeStore.onAlerts = { Notifier.post($0, provider: "Claude Code") }
        let claude = DashboardCoordinator.ProviderEntry(
            id: "claude", displayName: "Claude Code", tag: "C", store: claudeStore
        )

        var codex: DashboardCoordinator.ProviderEntry?
        if enabled.contains("codex"), CodexUsageClient.isAvailable() {
            let codexStore = UsageStore(provider: CodexUsageClient.live(), threshold: settings.threshold)
            codexStore.onAlerts = { Notifier.post($0, provider: "Codex") }
            codex = DashboardCoordinator.ProviderEntry(
                id: "codex", displayName: "Codex", tag: "X", store: codexStore
            )
        }

        var gemini: DashboardCoordinator.ProviderEntry?
        if enabled.contains("gemini"), GeminiUsageClient.isAvailable() {
            let geminiStore = UsageStore(provider: GeminiUsageClient.live(), threshold: settings.threshold)
            geminiStore.onAlerts = { Notifier.post($0, provider: "Gemini") }
            gemini = DashboardCoordinator.ProviderEntry(
                id: "gemini", displayName: "Gemini", tag: "G", store: geminiStore
            )
        }

        var cursor: DashboardCoordinator.ProviderEntry?
        if enabled.contains("cursor"), CursorUsageClient.isAvailable() {
            let cursorStore = UsageStore(provider: CursorUsageClient.live(), threshold: settings.threshold)
            cursorStore.onAlerts = { Notifier.post($0, provider: "Cursor") }
            cursor = DashboardCoordinator.ProviderEntry(
                id: "cursor", displayName: "Cursor", tag: "Cu", store: cursorStore
            )
        }

        let coordinator = DashboardCoordinator(
            entries: [claude] + [codex, gemini, cursor].compactMap { $0 }
        )
        Notifier.requestAuthorization()
        coordinator.startAll()
        _coordinator = StateObject(wrappedValue: coordinator)
        _thresholdEnabled = State(initialValue: settings.threshold != nil)
        _thresholdValue = State(initialValue: settings.threshold ?? Self.defaultThresholdPercent)
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
    }

    var body: some Scene {
        MenuBarExtra {
            GaugesView(
                coordinator: coordinator,
                thresholdEnabled: $thresholdEnabled,
                thresholdValue: $thresholdValue,
                launchAtLogin: $launchAtLogin,
                onThresholdChange: applyThreshold,
                onLaunchAtLoginChange: applyLaunchAtLogin,
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .task { await coordinator.refreshAll() }
        } label: {
            Text(coordinator.menuBarTitle)
                .foregroundStyle(menuBarColor(coordinator.menuBarColor))
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarColor(_ c: GaugeColor) -> Color {
        switch c {
        case .green: return .green; case .amber: return .orange; case .red: return .red; case .neutral, .muted: return .primary
        }
    }

    private func applyThreshold() {
        let value: Double? = thresholdEnabled ? thresholdValue : nil
        coordinator.setThresholdAll(value)
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
