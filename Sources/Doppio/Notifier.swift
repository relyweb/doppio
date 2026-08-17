// SPDX-License-Identifier: Apache-2.0
import Foundation
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for the handful of events
/// Doppio surfaces. Silently no-ops when notifications are disabled, the app
/// is unauthorized, or there is no app bundle (e.g. headless self-tests).
final class Notifier {
    private var authorized = false
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                // `authorized` is read on the main thread in post(); write it
                // there too so there is no cross-thread access.
                DispatchQueue.main.async { self?.authorized = granted }
            }
    }

    func post(title: String, body: String) {
        guard available, isEnabled(), authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
