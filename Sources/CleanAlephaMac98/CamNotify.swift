import UserNotifications

enum CamNotify {
    static func requestIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func cleaned(freed: Int64, lang: CopyLang) {
        guard freed > 0 else { return }
        requestIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = Copy.cleanNotifyTitle.t(lang)
        content.body = Copy.cleanNotifyBody(freed).t(lang)
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "cam98.clean.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
