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
    let providerID: String
    /// (command, providerID) — injected so the real Terminal launch stays out
    /// of previews and any future view test.
    let launch: (String, String) -> Void

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
                ForEach(healthy, id: \.key) { w in gauge(w, now: now) }
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
            VStack(alignment: .leading, spacing: 4) {
                Label(AuthRecovery.staleMessage(for: err, provider: providerID),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary)
                if let prompt = AuthRecovery.prompt(for: err, provider: providerID) {
                    reloginButton(prompt)
                }
            }
        }
    }

    private func gauge(_ w: UsageWindow, now: Date) -> some View {
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
            Label(w.countdown(now: now), systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
        .frame(width: 88)
    }

    @ViewBuilder private func errorView(_ error: FetchError) -> some View {
        // Auth failures are the only ones the user can act on, and the action
        // differs per provider — AuthRecovery owns both decisions.
        if let prompt = AuthRecovery.prompt(for: error, provider: providerID) {
            VStack(alignment: .leading, spacing: 6) {
                Label(prompt.message, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
                reloginButton(prompt)
            }
        } else {
            Label(unactionableMessage(error), systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func unactionableMessage(_ error: FetchError) -> String {
        switch error {
        case .rateLimited: return "Rate limited — pausing for a few minutes."
        case .network(let m): return "Network error: \(m)"
        case .decode: return "Couldn't read the usage response."
        // Auth errors are handled above; an unknown provider id lands here.
        case .authExpired, .notLoggedIn: return "Sign-in needed — run the CLI for \(title)."
        }
    }

    private func reloginButton(_ prompt: ReloginPrompt) -> some View {
        Button(prompt.buttonTitle) { launch(prompt.command, providerID) }
            .font(.caption)
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
    var launch: (String, String) -> Void = { command, providerID in
        TerminalLauncher.live.launch(command: command, providerID: providerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(coordinator.entries.enumerated()), id: \.element.id) { index, entry in
                ProviderSection(store: entry.store,
                                title: entry.displayName,
                                providerID: entry.id,
                                launch: launch)
                if index < coordinator.entries.count - 1 { Divider() }
            }
            Divider()
            thresholdControl
            aboutFooter
        }
        .padding(16)
        .frame(width: 320)
    }

    /// App identity + escape hatches. The popover is the app's only surface
    /// (menu-bar-only), so this is the one place a user can find the version,
    /// the project page, and Quit.
    private var aboutFooter: some View {
        HStack(spacing: 8) {
            Text("QuotaBar \(Self.appVersion)")
                .font(.caption2).foregroundStyle(.secondary)
            Link("GitHub", destination: URL(string: "https://github.com/pionion-ai/quotabar")!)
                .font(.caption2)
            Spacer()
            Button("Quit", action: onQuit)
        }
    }

    /// Bundle version; "dev" under bare `swift run` (no bundle).
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
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
