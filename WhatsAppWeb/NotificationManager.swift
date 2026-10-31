import CryptoKit
import UIKit
import UserNotifications

/// Bridges the web page's `Notification` API to iOS local notifications
/// and mirrors the unread count onto the app icon badge.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Called when the user taps a notification; receives the JS-side notification id.
    var onTap: ((String) -> Void)?

    /// Title of the chat currently on screen ("" while the chat list is showing), set by
    /// WebViewController from the page's "openChat" message.
    var openChatTitle: (() -> String)?

    private let center = UNUserNotificationCenter.current()

    // MARK: Avatar cache
    // Avatars are downloaded off the main thread, scaled down and kept on disk, keyed by a hash of the
    // icon URL. `avatarQueue` only does bookkeeping, decoding and file writes — never a request — so the
    // main thread can look the cache up synchronously without ever waiting on the network.
    private var avatarFiles: [String: URL] = [:]
    private var avatarInFlight: Set<String> = []
    private let avatarQueue = DispatchQueue(label: "AetherChat.avatarCache", qos: .utility)

    /// Avatars are attached as a 256 px square JPEG; iOS draws notification attachments much smaller.
    private static let avatarSide: CGFloat = 256
    private static let avatarMaxBytes = 512 * 1024

    func configure() {
        center.delegate = self
    }

    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
        }
    }

    /// One request per message, so messages of a chat stack through `threadIdentifier` (iOS groups by
    /// chat) instead of replacing each other. An avatar that is not cached yet is fetched in the
    /// background and appears on the next message from that chat: it never delays or drops this one.
    func post(id: String, title: String, body: String, tag: String?, icon: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["jsId": id]
        if let tag, !tag.isEmpty { content.threadIdentifier = tag }
        if let icon, !icon.isEmpty {
            let key = Self.cacheKey(for: icon)
            if let cached = cachedAvatar(for: key), let prepared = attachment(from: cached, key: key) {
                content.attachments = [prepared]
            } else {
                downloadAvatar(icon)
            }
        }
        let identifier = id.isEmpty ? UUID().uuidString : id
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Closing a chat removes every delivered notification of it (each message has its own identifier now).
    func close(tag: String) {
        guard !tag.isEmpty else { return }
        let notifications = center
        notifications.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == tag }.map { $0.request.identifier }
            if !ids.isEmpty { notifications.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func setBadge(_ count: Int) {
        center.setBadgeCount(count)
    }

    // MARK: Avatar downloads

    /// Icon URLs can be several KB of base64, so file names and cache keys are a hash of the URL.
    private static func cacheKey(for icon: String) -> String {
        SHA256.hash(data: Data(icon.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let avatarDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private func cachedAvatar(for key: String) -> URL? {
        avatarQueue.sync { avatarFiles[key] }
    }

    /// Starts a download unless the avatar is cached or already being fetched. Failures are dropped: an
    /// avatar is decoration, the notification is not.
    private func downloadAvatar(_ icon: String) {
        let key = Self.cacheKey(for: icon)
        let pending = avatarQueue.sync { () -> Bool in
            if avatarFiles[key] != nil || avatarInFlight.contains(key) { return true }
            avatarInFlight.insert(key)
            return false
        }
        guard !pending else { return }
        if let data = Self.inlineImage(from: icon) {
            storeAvatar(data, key: key) // data: URL: nothing to fetch, just decode and scale
        } else if let url = URL(string: icon), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self else { return }
                if let data, !data.isEmpty, data.count <= Self.avatarMaxBytes {
                    self.storeAvatar(data, key: key)
                } else {
                    self.forgetAvatar(key)
                }
            }.resume()
        } else {
            // A blob: URL only exists inside the page and cannot be fetched from here; Bridge.js inlines
            // those as data: URLs, so anything else is simply not an avatar we can use.
            forgetAvatar(key)
        }
    }

    private func forgetAvatar(_ key: String) {
        avatarQueue.async { [weak self] in self?.avatarInFlight.remove(key) }
    }

    /// Scales to a square, writes the JPEG, then caches it. Runs on `avatarQueue`, so neither decoding nor
    /// disk I/O ever happens on the main thread.
    private func storeAvatar(_ data: Data, key: String) {
        let url = Self.avatarDirectory.appendingPathComponent(key + ".jpg")
        avatarQueue.async { [weak self] in
            guard let self else { return }
            defer { self.avatarInFlight.remove(key) }
            guard let image = UIImage(data: data),
                  let jpeg = Self.square(image, side: Self.avatarSide)?.jpegData(compressionQuality: 0.8),
                  (try? jpeg.write(to: url, options: .atomic)) != nil else { return }
            self.avatarFiles[key] = url
        }
    }

    /// Center-cropped square, so avatars keep their proportions in the notification.
    private static func square(_ image: UIImage, side: CGFloat) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let target = CGSize(width: side, height: side)
        let scale = max(target.width / image.size.width, target.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(x: (target.width - drawn.width) / 2, y: (target.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
        }
    }

    /// Every notification gets its own copy of the file, because iOS moves the file a request was built from.
    private func attachment(from cached: URL, key: String) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-\(key.prefix(12))-\(UUID().uuidString).jpg")
        let source = (try? FileManager.default.copyItem(at: cached, to: copy)) != nil ? copy : cached
        return try? UNNotificationAttachment(identifier: key, url: source,
                                             options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"])
    }

    /// `data:` URLs are decoded locally; Bridge.js inlines WhatsApp's blob: icons into this form.
    private static func inlineImage(from icon: String) -> Data? {
        guard icon.hasPrefix("data:"), let comma = icon.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(icon[icon.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The chat you are reading is already on screen: keep the message in the notification list, but do
        // not make a noise about it. Every other chat, and the chat list itself, still plays the alert.
        let content = notification.request.content
        let open = openChatTitle?().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isOpenChat = !open.isEmpty
            && (content.title.caseInsensitiveCompare(open) == .orderedSame
                || content.threadIdentifier.caseInsensitiveCompare(open) == .orderedSame)
        completionHandler(isOpenChat ? [.list] : [.list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let jsId = response.notification.request.content.userInfo["jsId"] as? String {
            DispatchQueue.main.async { self.onTap?(jsId) }
        }
        completionHandler()
    }
}
