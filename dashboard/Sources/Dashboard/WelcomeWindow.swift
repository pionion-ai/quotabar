import AppKit
import SwiftUI

/// The first-run explanation, also reachable from the popover footer.
struct WelcomeView: View {
    let content: WelcomeContent
    let primaryTitle: String
    let onPrimary: () -> Void
    /// Nil once the app is running (reopened from the footer): no Quit button.
    let onQuit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title).font(.title2.bold())
                    Text(content.subtitle).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            section(icon: "key.fill", heading: content.passwordHeading) {
                Text(content.passwordBody).fixedSize(horizontal: false, vertical: true)
            }
            section(icon: "lock.shield.fill", heading: content.usageHeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(content.usageBullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(bullet).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                if let onQuit { Button("Quit", action: onQuit) }
                Button(primaryTitle, action: onPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func section<Body: View>(icon: String, heading: String,
                                     @ViewBuilder body: () -> Body) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(heading).font(.headline)
                body().font(.callout)
            }
        }
    }
}

/// Hosts WelcomeView in a plain AppKit window: the app is menu-bar-only
/// (LSUIElement), so it has no window scene of its own to show at launch.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    /// The first-run window's arguments, so "Finish setup…" can bring it back.
    private static var pendingFirstRun: (content: WelcomeContent, onContinue: () -> Void)?

    static func reopenFirstRun() {
        guard let pending = pendingFirstRun else { return }
        show(content: pending.content, firstRun: true, onContinue: pending.onContinue)
    }

    /// `firstRun`: no close button — the user either continues (consent) or
    /// quits; closing the window must not leave the app silently idle.
    static func show(content: WelcomeContent, firstRun: Bool, onContinue: @escaping () -> Void) {
        if firstRun { pendingFirstRun = (content, onContinue) }
        if let existing = window {
            // Never stack a second window: a hidden or minimized one comes back.
            existing.deminiaturize(nil)
            bringToFront(existing)
            return
        }
        let style: NSWindow.StyleMask = firstRun ? [.titled] : [.titled, .closable]
        let w = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        w.title = "QuotaBar"
        w.isReleasedWhenClosed = false
        // Closing a reopened (non-first-run) window via its close button.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        let view = WelcomeView(
            content: content,
            primaryTitle: firstRun ? "Continue" : "Close",
            onPrimary: { [weak w] in
                w?.close()
                if window === w { window = nil }
                if firstRun { pendingFirstRun = nil }
                onContinue()
            },
            onQuit: firstRun ? { NSApplication.shared.terminate(nil) } : nil)
        w.contentView = NSHostingView(rootView: view)
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        window = w
        bringToFront(w)
    }

    private static func bringToFront(_ w: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // activate() is advisory on macOS 14+ (e.g. a login-item launch).
        w.orderFrontRegardless()
    }
}
