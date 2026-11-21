import SwiftUI

private func swiftUIColor(_ c: GaugeColor) -> Color {
    switch c {
    case .green: return .green; case .amber: return .orange; case .red: return .red
    case .neutral: return .accentColor; case .muted: return .gray
    }
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
        let quotas = healthy.filter { $0.style != .share }
        let shares = healthy.filter { $0.style == .share }
        if !quotas.isEmpty { gaugeGrid(quotas, now: now) }
        if !shares.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage value by model").font(.caption).foregroundStyle(.secondary)
                if let note = shares.first?.note {
                    Text(note).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            gaugeGrid(shares, now: now)
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

    /// Three 88pt columns with 12pt gaps exactly fill the 288pt content width.
    private func gaugeGrid(_ windows: [UsageWindow], now: Date) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 12), count: 3),
                  alignment: .leading, spacing: 12) {
            ForEach(windows, id: \.key) { w in gauge(w, now: now) }
        }
    }

    private func gauge(_ w: UsageWindow, now: Date) -> some View {
        VStack(spacing: 4) {
            Gauge(value: w.usedPercent, in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text("\(Int(w.usedPercent.rounded()))%")
                    Text(w.style == .share ? "share" : "used").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .gaugeStyle(.accessoryCircular)
            .tint(swiftUIColor(w.color()))
            Text(w.label)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = w.detail {
                Text(detail).font(.caption2.monospacedDigit())
            }
            // A share of spend has no reset of its own worth repeating per model.
            if w.style != .share {
                Label(w.countdown(now: now), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
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
                if let hint = AuthRecovery.installHint(for: error, provider: providerID) {
                    Text(hint)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        } else {
            Label(unactionableMessage(error), systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)  // wrap: server messages are long
                .textSelection(.enabled)
        }
    }

    private func unactionableMessage(_ error: FetchError) -> String {
        switch error {
        case .rateLimited: return "Rate limited — pausing for a few minutes."
        case .network(let m): return "Network error: \(m)"
        case .decode: return "Couldn't read the usage response."
        case .unsupported(let m): return m  // normally hidden; see visibleEntries
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
            let entries = coordinator.visibleEntries
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                ProviderSection(store: entry.store,
                                title: entry.displayName,
                                providerID: entry.id,
                                launch: launch)
                if index < entries.count - 1 { Divider() }
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
