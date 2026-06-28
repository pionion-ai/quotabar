import SwiftUI

private func swiftUIColor(_ c: GaugeColor) -> Color {
    switch c { case .green: return .green; case .amber: return .orange; case .red: return .red }
}

struct GaugesView: View {
    @ObservedObject var store: UsageStore
    let now: Date
    @Binding var thresholdEnabled: Bool
    @Binding var thresholdValue: Double
    var onThresholdChange: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code Usage").font(.headline)

            switch store.loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let error):
                errorView(error)
            case .loaded(let windows):
                content(windows)
            }

            Divider()
            thresholdControl
            Button("Quit", action: onQuit)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder private func content(_ windows: [UsageWindow]) -> some View {
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
        if let checked = store.lastChecked {
            Text("checked \(checked.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func gauge(_ w: UsageWindow) -> some View {
        VStack(spacing: 4) {
            Gauge(value: w.remainingPercent, in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(w.remainingPercent.rounded()))%")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(swiftUIColor(w.color()))
            Text(w.label).font(.caption2).multilineTextAlignment(.center)
            Text(w.countdown(now: now)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 72)
    }

    private func errorView(_ error: FetchError) -> some View {
        let message: String
        switch error {
        case .authExpired: message = "Token expired — run `claude` once to refresh."
        case .notLoggedIn: message = "Not logged in to Claude Code."
        case .network(let m): message = "Network error: \(m)"
        case .decode: message = "Couldn't read the usage response."
        }
        return Label(message, systemImage: "wifi.exclamationmark")
            .font(.callout).foregroundStyle(.secondary)
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
        }
    }
}
