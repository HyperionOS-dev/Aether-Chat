<p align="center"><img src="WhatsAppWeb/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" alt=""></p>

# Aether Chat

Use a second WhatsApp or WhatsApp Business account on your iPhone, as a linked device.

iPhone Safari won't open web.whatsapp.com; it asks you to download the app instead. Aether Chat loads the official WhatsApp Web in a native iPhone app and adapts it to the phone.

Part of the Aether family of software. Based on [whatsapp-web-ios](https://github.com/Etelis/whatsapp-web-ios) by Etelis.

## Features

- Log in with the QR code or with an 8-character code sent to your phone number
- Phone layout: chat list and conversation as separate screens, with a back button and edge swipe
- One tap opens a chat; long-press opens WhatsApp's menu (reply, forward, delete…)
- iOS notifications, also in the background; one stack per chat, with the contact's photo, and the message only sounds when you are not already reading that chat; unread count on the app icon
- Voice notes, camera, photos/files, downloads via the share sheet
- `wa.me` links open the chat in this account
- Stays logged in; follows light/dark mode

## How it works

| Problem | Fix |
|---|---|
| WhatsApp sends phone browsers to a "download the app" page | macOS Safari user agent and `navigator.maxTouchPoints = 0` |
| WKWebView has no Service Workers | WhatsApp domains listed in `WKAppBoundDomains` |
| The desktop layout is at least 748px wide | `Layout.js` shows two phone-width pages: chat list and chat |
| iOS needs two taps on elements with hover styles | Taps are sent as clicks and long-presses as right-clicks |
| WKWebView has no `Notification` API | `Bridge.js` passes notifications to iOS; `hasFocus()` follows the app state |
| iOS suspends apps in the background | Inaudible audio keeps the page alive: a silent Web Audio graph where iOS allows it, otherwise a looping silent clip in an `<audio>` element |
| iOS stops that audio during calls, Siri, or when another app takes the audio session | `Bridge.js` restarts it and reports its real state; the app watches audio interruptions and re-arms it, then falls back to the `<audio>` element if Web Audio cannot run |

| File | Role |
|---|---|
| `WebViewController.swift` | Web view setup, navigation, keyboard, badge, lifecycle, audio interruptions, keep-alive mode, shake menu |
| `Bridge.js` | Notification shim (avatars included), which chat is open, focus, keep-alive (Web Audio + audio element) and its heartbeat |
| `Layout.js` | Phone layout, back navigation, touch handling, login-screen scaling |
| `NotificationManager.swift` | Local notifications with avatars, grouped per chat, and badge |
| `DownloadManager.swift` | Saves downloads and shows the share sheet |

## Install

Requires an iPhone on iOS 17 or later and an Apple ID. With a free account the app expires after 7 days; with a paid developer account, after a year. SideStore can refresh it automatically.

No Mac needed. The IPA is built on GitHub:

1. Go to the **Actions** tab, choose **Build IPA**, and press **Run workflow**.
2. When the run turns green, open the **Releases** page and download `AetherChat.ipa`.
3. Open SideStore, go to **My Apps**, tap **+**, and pick the IPA. SideStore signs it with your Apple ID and installs it.
4. If the app won't open, trust your Apple ID under **Settings → General → VPN & Device Management**, and make sure **Developer Mode** is on.
5. On the phone that already has the account, go to **Settings → Linked devices → Link a device** and scan the QR code shown in the app. Or tap **Log in with phone number** in the app and enter the code on that phone.

The app name on the home screen is set by `APP_DISPLAY_NAME` in the workflow file (`.github/workflows/build.yml`).

### Building with Xcode instead

Requires Xcode 16 or later. Create `Local.xcconfig` (git-ignored):

```
DEVELOPMENT_TEAM = ABCDE12345
PRODUCT_BUNDLE_IDENTIFIER = com.aether.chat
APP_DISPLAY_NAME = Aether Chat
```

Open `WhatsAppWeb.xcodeproj`, select your iPhone and press **Run** (⌘R).

## Use

- **Shake** the phone for Reload, the background-connection toggle, its mode, and a zoomable desktop layout.
- **Stay connected in background** is on by default; you'll find it under the app's name in the iOS Settings app. It uses more battery. Without it, notifications only arrive while the app is open.
- **Background mode: Auto** (the default) keeps the connection with a silent Web Audio graph, which shows no player on the lock screen. If iOS won't keep that graph running, the app switches to **Audio element** by itself and remembers it; that mode always works, but iOS shows a player card with the unread count while it runs. Pick either one from the shake menu to override.
- **Mix with other audio** (Settings app, on by default) keeps music from other apps playing while the connection is held. Turn it off if another app's sound goes quiet.

## Limitations

- Calls aren't supported; WhatsApp Web doesn't offer them in this browser.
- Notifications rely on the app being kept alive, so they stop if you force-quit it.
- The lock-screen player card disappears only while the Web Audio mode is running; on a device where it cannot, the app falls back to the audio element and the card is back.
- The connection can still drop, for example when another app takes the audio session; the app re-arms it after interruptions, but a message that arrives during the gap is only picked up when the connection returns.
- The layout depends on WhatsApp Web's page structure. If an update breaks it, switch to the desktop layout from the shake menu.

## Disclaimer

Not affiliated with WhatsApp or Meta. The app only displays the official web.whatsapp.com and does not use an unofficial protocol. Use it at your own risk.

## License

MIT. See `LICENSE`. Original work by Etelis.
