import Foundation
import LimiarCore
import UserNotifications

@MainActor
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ notice: PolicyNotice) {
        switch notice {
        case .limitReached(let limit):
            post(title: String(localized: "Paused at \(limit)%"),
                 body: String(localized: "Your Mac is running on battery until it's time to charge again."))
        case .topUpCompleted:
            post(title: String(localized: "Fully charged"),
                 body: String(localized: "It stays full while plugged in. The limit returns when you unplug."))
        case .dischargeCompleted(let target):
            post(title: String(localized: "Reached \(target)%"),
                 body: String(localized: "Discharge finished. Your usual limit is back on."))
        }
    }

    static func postError(_ message: String) {
        post(title: String(localized: "Limiar needs attention"), body: message)
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
