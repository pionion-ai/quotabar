import Foundation
import UserNotifications

enum Notifier {
    /// `provider` is the display name ("Codex", "Cursor"…) so an alert says
    /// which tool's limit it is about.
    static func body(for event: AlertEvent, provider: String) -> (title: String, body: String) {
        let title = "\(provider) usage"
        switch event {
        case .reached(let label, let countdown):
            return (title, "\(label) limit reached · available in \(countdown)")
        case .approaching(let label, let countdown):
            return (title, "\(label) at threshold · resets in \(countdown)")
        }
    }

    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ events: [AlertEvent], provider: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        for event in events {
            let (title, body) = body(for: event, provider: provider)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
    }
}
