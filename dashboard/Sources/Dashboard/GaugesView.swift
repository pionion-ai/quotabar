import SwiftUI

private func swiftUIColor(_ c: GaugeColor) -> Color {
    switch c { case .green: return .green; case .amber: return .orange; case .red: return .red }
}

/// One labeled provider block in the popover: a header with the provider name,
/// then its loadState-driven content. Each provider ticks its own clock via
/// `store.currentTime`.
private struct ProviderSection: View {
    @ObservedObject var store: UsageStore
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            switch store.loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let error):
                errorView(error)
            case .loaded(let windows):
                content(windows)
            }
        }
    }

    @ViewBuilder private func content(_ windows: [UsageWindow]) -> some View {
        let now = store.currentTime
        let reached = windows.filter { if case .reached = $0.state { return true }; return false }
        let healthy = windows.filter { if case .ok = $0.state { return true }; return false }

        ForEach(reached, id: \.key) { w in
            VStack(alignment: .leading, spacing: 4) {
                Label("\(w.label) limit reached", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red).font(.subheadline.bold())
                Text("available in \(w.countdown(now: now))")
                    .font(.system(.title, design: .monospaced))
            }
        }
        if !healthy.isEmpty {
            HStack(spacing: 16) {
                ForEach(healthy, id: \.key) { w in gauge(w) }
            }
        }
        if reached.isEmpty && healthy.isEmpty {
            Text("No usage windows reported.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let checked = store.lastChecked {
            Text("checked \(checked.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let err = store.lastError {
            Label(staleMessage(err), systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func staleMessage(_ error: FetchError) -> String {
        switch error {
        case .rateLimited: return "Rate limited — retrying soon"
        default:           return "Couldn't refresh — showing last update"
        }
    }

    private func gauge(_ w: UsageWindow) -> some View {
        VStack(spacing: 4) {
            Gauge(value: w.usedPercent, in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text("\(Int(w.usedPercent.rounded()))%")
                    Text("used").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .gaugeStyle(.accessoryCircular)
            .tint(swiftUIColor(w.color()))
            Text(w.label)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Label(w.countdown(now: store.currentTime), systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
        .frame(width: 88)
    }

    private func errorView(_ error: FetchError) -> some View {
        let message: String
        switch error {
        case .authExpired: message = "Token expired — run `claude` once to refresh."
        case .notLoggedIn: message = "Not logged in to Claude Code."
        case .rateLimited: message = "Rate limited — pausing for a few minutes."
        case .network(let m): message = "Network error: \(m)"
        case .decode: message = "Couldn't read the usage response."
        }
        return Label(message, systemImage: "wifi.exclamationmark")
            .font(.callout).foregroundStyle(.secondary)
    }
}

struct GaugesView: View {
    @ObservedObject var coordinator: DashboardCoordinator
    @Binding var thresholdEnabled: Bool
    @Binding var thresholdValue: Double
    @Binding var launchAtLogin: Bool
    var onThresholdChange: () -> Void
    var onLaunchAtLoginChange: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(coordinator.entries) { entry in
                ProviderSection(store: entry.store, title: entry.displayName)
                Divider()
            }
            thresholdControl
            Button("Quit", action: onQuit)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var thresholdControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Alert me at threshold", isOn: $thresholdEnabled)
                .onChange(of: thresholdEnabled) { _ in onThresholdChange() }
            if thresholdEnabled {
                HStack {
                    Text("\(Int(thresholdValue))% used")
                    Slider(value: $thresholdValue, in: 50...99, step: 1)
                        .onChange(of: thresholdValue) { _ in onThresholdChange() }
                }
            }
            if LoginItem.isAvailable {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _ in onLaunchAtLoginChange() }
            }
        }
    }
}
