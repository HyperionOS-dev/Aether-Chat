import AVFoundation
import UIKit
import WebKit

/// Hosts web.whatsapp.com in a WKWebView and bridges it to iOS: notifications, badge,
/// keyboard, downloads, back navigation and background keep-alive.
final class WebViewController: UIViewController {
    static let home = URL(string: "https://web.whatsapp.com/")!

    /// Desktop Safari on macOS. WhatsApp Web redirects mobile user agents to a "download the app" page.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Keep WhatsApp connected in the background (silent in-page audio) so notifications arrive.
    /// On by default; toggled from the shake menu or the Settings app.
    static var keepAliveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAlive") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAlive") }
    }

    /// How the connection is held open. "Auto" tries Web Audio (which iOS does not turn into a
    /// lock-screen media card) and Bridge.js/native fall back to the audio element for good when it does
    /// not run on this device; "Audio element" always shows that card. Toggled from the shake menu.
    static var keepAliveModeWebAudio: Bool {
        get { UserDefaults.standard.string(forKey: "keepAliveMode") != "element" }
        set { UserDefaults.standard.set(newValue ? "auto" : "element", forKey: "keepAliveMode") }
    }

    /// The mode handed to Bridge.js, resolved from the setting above.
    static var keepAliveMode: String { keepAliveModeWebAudio ? "webaudio" : "element" }

    /// Mix the inaudible keep-alive audio with other apps' audio instead of taking the audio session.
    /// On by default; the toggle lives in the app's section of the Settings app.
    static var mixAudio: Bool {
        get { UserDefaults.standard.object(forKey: "mixAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mixAudio") }
    }

    /// Turbo mode: the page renders without backdrop blur, shadows and animations (Settings app and shake
    /// menu). On by default — blur is one of the most expensive things on a phone GPU and buys nothing.
    static var turbo: Bool {
        get { UserDefaults.standard.object(forKey: "turbo") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "turbo") }
    }

    private var webView: WKWebView!
    private var webViewBottom: NSLayoutConstraint!
    private let bottomFill = UIView()
    private let downloads = DownloadManager()
    private let backSwipeLeft = UIScreenEdgePanGestureRecognizer()
    private let backSwipeRight = UIScreenEdgePanGestureRecognizer()
    private var titleObservation: NSKeyValueObservation?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastBadge = -1
    /// Chat title the page reports as open on screen ("" in the chat list); silences its notifications.
    private var openChatTitle = ""
    /// Last time the page confirmed it is still alive in the background (see the heartbeat watchdog).
    private var lastHeartbeat = Date.distantPast
    private var heartbeatTimer: Timer?
    // Performance report ("Measure performance" in the shake menu): app start, main-thread stalls and how
    // long it took before the chat list was on screen.
    private let launchedAt = Date()
    private var startupSeconds: TimeInterval?
    private var hangProbe: Timer?
    private var hangTick: Date?
    private var hangWorstMs = 0
    // Launch: a throwaway web view warms the web content process, and the last frame of the last session is
    // shown until the real page has painted.
    private var warmUp: WKWebView?
    private let launchImage = UIImageView()
    /// Whether the page has accepted the Turbo setting; retried on the first "layout" message if not.
    private var turboSynced = false

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent: the linked session survives relaunches
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // With WhatsApp's domains in WKAppBoundDomains (Info.plist) WKWebView enables Service Workers,
        // which WhatsApp Web uses for media and downloads.
        config.limitsNavigationsToAppBoundDomains = true

        let content = WKUserContentController()
        for name in ["Bridge", "Layout"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        content.add(WeakScriptHandler(self), name: "dw")
        config.userContentController = content

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.desktopUserAgent
        #if DEBUG
        webView.isInspectable = true // Safari > Develop on the Mac
        #endif
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        downloads.presenter = self

        // Status bar / home indicator strips are painted with the page's edge colors ("edges" message).
        let root = UIView()
        root.backgroundColor = .systemBackground
        bottomFill.backgroundColor = .systemBackground
        root.addSubview(bottomFill)
        root.addSubview(webView)
        // Above the web view: the last frame of the last session, so launching does not show a white screen.
        launchImage.contentMode = .scaleAspectFill
        launchImage.clipsToBounds = true
        launchImage.isUserInteractionEnabled = false
        launchImage.isHidden = true
        root.addSubview(launchImage)
        bottomFill.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        launchImage.translatesAutoresizingMaskIntoConstraints = false
        webViewBottom = webView.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            webViewBottom,
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            launchImage.topAnchor.constraint(equalTo: root.topAnchor),
            launchImage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            launchImage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            launchImage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomFill.topAnchor.constraint(equalTo: root.centerYAnchor),
            bottomFill.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomFill.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomFill.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationManager.shared.onTap = { [weak self] jsId in
            self?.webView.callAsyncJavaScript("window.__dw?.notificationClicked(id)", arguments: ["id": jsId], in: nil, in: .page)
        }
        NotificationManager.shared.openChatTitle = { [weak self] in self?.openChatTitle ?? "" }
        titleObservation = webView.observe(\.title) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.updateBadge(fromTitle: webView.title) }
        }
        for (gesture, edge) in [(backSwipeLeft, UIRectEdge.left), (backSwipeRight, UIRectEdge.right)] {
            gesture.edges = edge
            gesture.isEnabled = false
            gesture.addTarget(self, action: #selector(handleBackSwipe(_:)))
            webView.addGestureRecognizer(gesture)
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        // A call, Siri or another app taking the audio session stops the silent keep-alive, and nothing
        // restarted it before. iOS tells us when the interruption is over: that is the moment to re-arm.
        nc.addObserver(self, selector: #selector(audioSessionInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(audioServicesWereReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        showLaunchSnapshot()
        prewarmWebProcess()
        reload()
    }

    func reload() {
        webView.load(URLRequest(url: Self.home))
    }

    // MARK: - Keyboard

    /// Shrinks the web view above the keyboard so the message box stays visible.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        var overlap: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification, let window = view.window {
            let keyboard = view.convert(endFrame, from: window.screen.coordinateSpace)
            overlap = max(0, view.bounds.maxY - keyboard.minY - view.safeAreaInsets.bottom)
        }
        guard webViewBottom.constant != -overlap else { return }
        webViewBottom.constant = -overlap
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: UIView.AnimationOptions(rawValue: curve << 16)) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - App lifecycle

    @objc private func appWillResignActive() {
        // Start the keep-alive while the page is still visible; WebKit may refuse to start playback later.
        armKeepAlive()
    }

    @objc private func appDidEnterBackground() {
        // WhatsApp only notifies while the page reports no focus.
        webView.evaluateJavaScript("window.__dw && window.__dw.setAppActive(false)")
        beginBackgroundTask()
        startHeartbeatWatchdog()
        saveLaunchSnapshot()
    }

    @objc private func appDidBecomeActive() {
        endBackgroundTask()
        stopHeartbeatWatchdog()
        applyTurbo() // the Settings app toggle may have changed while we were away
        webView.evaluateJavaScript("window.__dw && (window.__dw.setAppActive(true), window.__dw.keepAlive(false))")
        refreshBadge() // notification permission may have changed in Settings
    }

    /// A new document (e.g. a reload while in the background) starts out focused and silent; re-apply background state.
    private func pageReady() {
        guard UIApplication.shared.applicationState == .background else { return }
        webView.evaluateJavaScript("window.__dw.setAppActive(false)")
        armKeepAlive()
    }

    // MARK: - Background keep-alive

    /// Tells the page to hold the connection open in the mode iOS has accepted so far.
    private func armKeepAlive() {
        guard Self.keepAliveEnabled else { return }
        applyAudioSession()
        lastHeartbeat = Date()
        webView.evaluateJavaScript("window.__dw && window.__dw.keepAlive(true, '\(Self.keepAliveMode)')")
    }

    /// The keep-alive plays inaudible audio, which needs an active audio session. Mixing with other apps
    /// is the default so music keeps playing; WebKit manages its own session for the web content, so this
    /// is best effort and never fatal.
    private func applyAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = Self.mixAudio ? [.mixWithOthers] : []
        try? session.setCategory(.playback, mode: .default, options: options)
        try? session.setActive(true)
    }

    /// A Web Audio graph that is not running (iOS refused it without a tap, or this WebKit has no Audio
    /// Session API) means no keep-alive at all, so the audio element takes over for good. The choice is
    /// remembered, and the shake menu can set it back to Auto.
    private func keepAliveStateChanged(_ body: [String: Any]) {
        let mode = body["mode"] as? String ?? ""
        let state = body["state"] as? String ?? ""
        guard mode == "webaudio", state != "running", Self.keepAliveModeWebAudio, Self.keepAliveEnabled else { return }
        Self.keepAliveModeWebAudio = false
        armKeepAlive()
    }

    /// While the app is in the background the page beats every 20 s. Beats stopping means the Web Audio
    /// graph was suspended (a call, another app, iOS reclaiming the session) and the page is frozen with
    /// it, so nothing would arrive: switch to the audio element, which iOS keeps running.
    private func startHeartbeatWatchdog() {
        stopHeartbeatWatchdog()
        lastHeartbeat = Date()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.heartbeatWatched() }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeatWatchdog() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func heartbeatWatched() {
        guard Self.keepAliveEnabled, Self.keepAliveModeWebAudio,
              UIApplication.shared.applicationState != .active,
              Date().timeIntervalSince(lastHeartbeat) > 60 else { return }
        lastHeartbeat = Date()
        Self.keepAliveModeWebAudio = false
        armKeepAlive()
    }

    /// iOS ends an interruption (phone call, Siri, another app) with permission to resume; before this,
    /// the silent loop stayed paused until the app was reopened.
    @objc private func audioSessionInterrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .ended:
            // iOS only ends the notification when playback may continue, so always try to start again.
            rearmKeepAliveIfBackgrounded()
        default:
            break // .began: nothing to do until iOS allows playback again
        }
    }

    /// The media services restart (rare) loses every audio session; start the keep-alive again.
    @objc private func audioServicesWereReset() {
        rearmKeepAliveIfBackgrounded()
    }

    private func rearmKeepAliveIfBackgrounded() {
        guard Self.keepAliveEnabled, UIApplication.shared.applicationState != .active else { return }
        armKeepAlive()
    }

    /// Grace period for messages arriving right after leaving the app (the only one without keep-alive).
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WhatsAppGrace") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Unread badge

    /// "(3) WhatsApp Business – …" -> 3, "WhatsApp" -> 0, anything else (title flashing) -> nil.
    static func unreadCount(fromTitle title: String?) -> Int? {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") {
            // wholeNumberValue accepts non-Latin digits; separators such as "1,234" are skipped.
            let digits = t[t.index(after: t.startIndex)..<close].compactMap(\.wholeNumberValue)
            return digits.isEmpty ? nil : digits.reduce(0) { $0 * 10 + $1 }
        }
        return t.hasPrefix("WhatsApp") ? 0 : nil
    }

    private func updateBadge(fromTitle title: String?) {
        guard let count = Self.unreadCount(fromTitle: title), count != lastBadge else { return }
        lastBadge = count
        NotificationManager.shared.setBadge(count)
    }

    private func refreshBadge() {
        lastBadge = -1
        updateBadge(fromTitle: webView.title)
    }

    // MARK: - Back swipe (Layout.js reports which page is shown)

    private func layoutChanged(_ body: [String: Any]) {
        let inChat = body["inChat"] as? Bool ?? false
        let rtl = body["rtl"] as? Bool ?? false
        backSwipeLeft.isEnabled = inChat && !rtl
        backSwipeRight.isEnabled = inChat && rtl
    }

    @objc private func handleBackSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended, abs(gesture.translation(in: webView).x) > 60 else { return }
        webView.evaluateJavaScript("window.__wam && window.__wam.back()")
    }

    // MARK: - Shake menu

    // Shake events travel up the responder chain from the web view, so the page keeps focus.
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, presentedViewController == nil else { return }
        webView.evaluateJavaScript("window.__wam ? window.__wam.mode() : 'mobile'") { [weak self] result, _ in
            self?.showMenu(desktopLayout: (result as? String) == "desktop")
        }
    }

    private func showMenu(desktopLayout: Bool) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Reload", style: .default) { [weak self] _ in self?.reload() })
        let keep = Self.keepAliveEnabled
        sheet.addAction(UIAlertAction(title: keep ? "Background connection: On ✓" : "Background connection: Off",
                                      style: .default) { [weak self] _ in self?.setKeepAlive(!keep) })
        let webAudio = Self.keepAliveModeWebAudio
        sheet.addAction(UIAlertAction(title: webAudio ? "Background mode: Auto ✓" : "Background mode: Auto",
                                      style: .default) { _ in Self.keepAliveModeWebAudio = true })
        sheet.addAction(UIAlertAction(title: webAudio ? "Background mode: Audio element" : "Background mode: Audio element ✓",
                                      style: .default) { _ in Self.keepAliveModeWebAudio = false })
        sheet.addAction(UIAlertAction(title: Self.turbo ? "Turbo mode: On ✓" : "Turbo mode: Off",
                                      style: .default) { [weak self] _ in
            Self.turbo = !Self.turbo
            self?.applyTurbo()
        })
        sheet.addAction(UIAlertAction(title: "Measure performance", style: .default) { [weak self] _ in
            self?.measurePerformance()
        })
        sheet.addAction(UIAlertAction(title: desktopLayout ? "Use phone layout" : "Use desktop layout (zoomable)",
                                      style: .default) { [weak self] _ in
            self?.webView.evaluateJavaScript("window.__wam && window.__wam.setMode('\(desktopLayout ? "mobile" : "desktop")')")
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func setKeepAlive(_ on: Bool) {
        guard on else { Self.keepAliveEnabled = false; return }
        let alert = UIAlertController(
            title: "Stay connected in background?",
            message: "Keeps WhatsApp connected after you leave the app so new messages still notify you. It plays inaudible audio to stay awake, which uses more battery. It mixes with other apps' audio by default (Settings ▸ Mix with other audio).",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Turn On", style: .default) { _ in Self.keepAliveEnabled = true })
        present(alert, animated: true)
    }

    // MARK: - Performance

    /// Pushes the Turbo setting into the page; the JS side ignores it when nothing changed. The result says
    /// whether the page was ready for it: Bridge.js posts its "ready" message before Layout.js has defined
    /// `__wam`, so a cold start needs the retry from the first "layout" message (see the message switch).
    private func applyTurbo() {
        let call = "window.__wam ? (window.__wam.setTurbo(\(Self.turbo ? "true" : "false")), true) : false"
        webView.evaluateJavaScript(call) { [weak self] result, _ in
            self?.turboSynced = (result as? Bool) ?? false
        }
    }

    private func measurePerformance() {
        startHangProbe()
        webView.evaluateJavaScript("window.__dw && window.__dw.measure && window.__dw.measure(3000)")
    }

    /// A timer that should fire every 250 ms: how late it fires is exactly how long the main thread was
    /// blocked. Cheap, and it catches the stalls the frame counter cannot see (React re-renders, layout).
    private func startHangProbe() {
        stopHangProbe()
        hangWorstMs = 0
        hangTick = Date()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let previous = self.hangTick else { return }
            self.hangWorstMs = max(self.hangWorstMs, Int(Date().timeIntervalSince(previous) * 1000))
            self.hangTick = Date()
        }
        RunLoop.main.add(timer, forMode: .common)
        hangProbe = timer
    }

    private func stopHangProbe() {
        hangProbe?.invalidate()
        hangProbe = nil
        hangTick = nil
    }

    private func showPerfReport(_ body: [String: Any]) {
        stopHangProbe()
        var lines = [
            "Turbo mode: \((body["turbo"] as? Bool ?? false) ? "on" : "off")",
            "Frames per second (idle): \(body["fps"] as? Int ?? 0)",
            "Frames over 32 ms: \(body["slowFrames"] as? Int ?? 0) (worst \(body["worstFrameMs"] as? Int ?? 0) ms)",
            "Long tasks over 50 ms: \(body["longTasks"] as? Int ?? 0)",
        ]
        if let mb = Self.memoryFootprintMB() { lines.append(String(format: "Memory: %.0f MB", mb)) }
        if hangWorstMs > 0 { lines.append("Main thread stalls: up to \(hangWorstMs) ms") }
        if let startup = startupSeconds { lines.append(String(format: "Launch to chat list: %.1f s", startup)) }
        let alert = UIAlertController(title: "Performance", message: lines.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Resident size of the whole app, web content included. `phys_footprint` is the number iOS shows in
    /// Settings and the one the memory limit is measured against.
    static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    // MARK: - Launch

    /// The last frame of the last session, kept in Caches (iOS may purge it, then we simply start white).
    private static let snapshotURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("launch.jpg")

    /// Taken while the app is still on screen: backgrounding can detach the view and the snapshot comes back empty.
    /// At most once a minute, because this is a splash image and every other app switch would otherwise pay
    /// for a full-screen encode and a multi-megabyte write.
    private func saveLaunchSnapshot() {
        guard let url = Self.snapshotURL else { return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) < 60 { return }
        webView.takeSnapshot(with: nil) { image, _ in
            // JPEG rather than PNG: a few hundred KB instead of a few MB, for an image that is hidden again
            // as soon as the page paints. It is a snapshot of the screen, not an asset.
            guard let data = image?.jpegData(compressionQuality: 0.7) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Covers the page while it loads, so the app opens on your last screen instead of a white rectangle.
    private func showLaunchSnapshot() {
        guard let url = Self.snapshotURL, let image = UIImage(contentsOfFile: url.path) else { return }
        launchImage.image = image
        launchImage.isHidden = false
        // A stale frame must never outlive the real page for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hideLaunchSnapshot() }
    }

    private func hideLaunchSnapshot() {
        guard !launchImage.isHidden else { return }
        launchImage.isHidden = true
        launchImage.image = nil // a full-screen PNG, no reason to keep the pixels
    }

    /// Starts the web content process while the UI is still coming up. WebKit shares one process pool per
    /// app, so the real page's first navigation does not pay for spawning it; this view is then thrown away.
    private func prewarmWebProcess() {
        let warm = WKWebView()
        warm.loadHTMLString("<html><body></body></html>", baseURL: nil)
        warmUp = warm
    }

    // MARK: - Helpers

    /// Parses "rgb(r, g, b)" / "rgba(r, g, b, a)" from getComputedStyle.
    static func color(fromCSS css: String?) -> UIColor? {
        guard let css, let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let parts = css[css.index(after: open)..<close].split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard parts.count >= 3 else { return nil }
        return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    /// Only WhatsApp Web itself loads in the web view; any other page would replace the session.
    private static func isWebApp(_ url: URL) -> Bool {
        url.host?.lowercased() == home.host
    }

    /// Opens a link outside the web view. Click-to-chat links (wa.me/<number>, api.whatsapp.com/send)
    /// open the chat in this account instead of the phone's WhatsApp app.
    private func openExternally(_ url: URL) {
        let host = url.host?.lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let phone = host == "wa.me" ? url.pathComponents.dropFirst().first
            : host == "api.whatsapp.com" && url.path == "/send" ? query.first { $0.name == "phone" }?.value : nil
        if let phone, !phone.isEmpty, phone.allSatisfy(\.isNumber) {
            var chat = URLComponents(string: "https://web.whatsapp.com/send")!
            chat.queryItems = [URLQueryItem(name: "phone", value: phone)] + query.filter { $0.name == "text" }
            webView.load(URLRequest(url: chat.url!))
        } else {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Messages from Bridge.js / Layout.js

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "notify":
            NotificationManager.shared.post(id: body["id"] as? String ?? UUID().uuidString,
                                            title: body["title"] as? String ?? "WhatsApp",
                                            body: body["body"] as? String ?? "",
                                            tag: body["tag"] as? String,
                                            icon: body["icon"] as? String)
        case "closeNotification":
            if let tag = body["tag"] as? String { NotificationManager.shared.close(tag: tag) }
        case "openChat":
            openChatTitle = body["title"] as? String ?? ""
        case "keepAlive":
            keepAliveStateChanged(body)
        case "keepBeat":
            lastHeartbeat = Date()
        case "perf":
            showPerfReport(body)
        case "ready":
            applyTurbo() // keep the page in sync with the setting after a reload
            pageReady()
        case "loggedIn":
            if startupSeconds == nil { startupSeconds = Date().timeIntervalSince(launchedAt) }
            hideLaunchSnapshot() // the chat list is on screen; the snapshot has done its job
            warmUp = nil         // the real view owns the warm process from here
            // Asked only once logged in, not on the QR screen.
            NotificationManager.shared.requestAuthorization { [weak self] granted in
                if granted { self?.refreshBadge() }
            }
        case "edges":
            if let top = Self.color(fromCSS: body["top"] as? String) { view.backgroundColor = top }
            if let bottom = Self.color(fromCSS: body["bottom"] as? String) { bottomFill.backgroundColor = bottom }
        case "layout":
            if !turboSynced { applyTurbo() } // Layout.js posted this, so __wam exists by now
            layoutChanged(body)
        default:
            break
        }
    }
}

// MARK: - Navigation & downloads

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.download) }
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
        let isSubframe = navigationAction.targetFrame?.isMainFrame == false
        if isSubframe || Self.isWebApp(url) || ["blob", "data", "about"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.allow)
        } else {
            openExternally(url) // other sites to Safari; tel:, mailto:, maps: to their apps
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = disposition?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(!navigationResponse.canShowMIMEType || isAttachment ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS killed the web process (memory pressure); reconnect. In the background, pageReady()
        // restores the background state once the new page starts.
        if UIApplication.shared.applicationState == .background { beginBackgroundTask() }
        reload()
    }
}

// MARK: - New windows, camera/mic, JS dialogs

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open: WhatsApp Web URLs load here, everything else opens outside.
        if let url = navigationAction.request.url {
            if Self.isWebApp(url) { webView.load(navigationAction.request) } else { openExternally(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host.lowercased() == "web.whatsapp.com" ? .grant : .prompt)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the view controller.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
