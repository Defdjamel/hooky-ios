# Hooky for iOS

A native chat between your users and your team, in three lines. The conversation is built with SwiftUI (no web view), follows the device's language, dark mode and Dynamic Type, and works from SwiftUI and UIKit apps.

- iOS 15+ and Mac Catalyst 15+
- Swift 6, strict concurrency
- No third-party dependency (URLSession, URLSessionWebSocketTask, PhotosUI, Keychain)

## Installation

Swift Package Manager: in Xcode, **File › Add Package Dependencies…**, then paste the repository URL. Or in `Package.swift`:

```swift
.package(url: "https://github.com/<owner>/hooky-ios.git", from: "1.0.0") // the public repository's URL
```

and add `"Hooky"` to your target's dependencies.

## The three lines

```swift
import Hooky

// 1. At launch (App.init or application(_:didFinishLaunchingWithOptions:))
Hooky.configure(siteKey: "YOUR_PUBLIC_SITE_KEY")

// 2. The floating bubble, on any SwiftUI view
ContentView().hookyBubble()

// 3. Or open the conversation from your own button
Hooky.open()
```

Your site's public key is in Hooky › Sites › Install (the same key as the web bubble's `data-site-key`).

## API

| Call | What it does |
| --- | --- |
| `Hooky.configure(siteKey:apiURL:language:)` | Starts the SDK: loads the site's name, color and greeting, resumes the saved conversation and opens the live connection. `apiURL` is for tests against your own server (default `https://api.heyhooky.com`); `language` forces `fr`, `en`, `es`, `pt`, `it` or `de` (the device language otherwise, English by default). |
| `Hooky.identify(name:email:)` | Optional. Sent when the conversation starts; the chat then skips its name and email form. `nil` clears it. |
| `Hooky.open()` / `Hooky.open(from:)` | Presents the conversation as a full-height sheet, from the top-most view controller or the one you give. |
| `Hooky.close()` | Dismisses it. |
| `Hooky.track(_:value:properties:)` | Sends an event to the site's stats, like `Hooky.track` on the web. Never throws, callable from any thread, even before `configure` (events wait for it). Properties are flat strings, numbers or booleans. |
| `Hooky.reset()` | Forgets the conversation, identity and draft. Call it when your user logs out. |
| `Hooky.shared.unreadCount` | Unread team messages, `@Published` and live. Also `Hooky.unreadCountUpdates()` (an `AsyncStream<Int>`) and `Hooky.shared.onUnreadCountChange`. |
| `Hooky.shared.siteName`, `isOpen`, `isConfigured` | `@Published` state, for your own UI. |

```swift
Hooky.track("signup")
Hooky.track("order", value: 49.9, properties: ["plan": "pro", "seats": 3, "trial": false])
```

### SwiftUI

```swift
ContentView()
    .hookyBubble()                                   // bottom corner (side set for the site)
    .hookyBubble(alignment: .bottomLeading, padding: 24, hidden: isCheckout)

HookyBubble(size: 56)                                // the button alone, to place yourself
HookyBubble { showMyOwnSheet = true }                // with your own action

.sheet(isPresented: $chat) { HookyConversationView() } // present the conversation yourself
```

Badge in a tab bar:

```swift
@ObservedObject var hooky = Hooky.shared
...
SupportView().tabItem { Label("Help", systemImage: "questionmark.bubble") }
    .badge(hooky.unreadCount)
```

### UIKit

```swift
Hooky.configure(siteKey: "YOUR_PUBLIC_SITE_KEY")
Hooky.showBubble(in: view)          // the floating button, bottom right (leading: true for left)
Hooky.open(from: self)              // or from your own button

let bubble = HookyBubbleView()      // a UIView to lay out yourself

Task {
    for await count in Hooky.unreadCountUpdates() { tabBarItem.badgeValue = count > 0 ? "\(count)" : nil }
}
```

## Attachments and permissions

Your users can send up to 4 photos (JPEG, PNG, HEIC, WebP, GIF) or PDFs of 10 MB per message. Photos from the library use the system picker (no permission needed) and are resized to 2048 px before upload. Files come from the Files app.

To offer the camera, add `NSCameraUsageDescription` to your app's Info.plist; without it, the camera option is simply hidden. Received photos open full screen (zoom, swipe, share); received files open in Quick Look.

## What the SDK sends and stores

- Every request carries `X-Hooky-Client: hooky-ios/<SDK version>` and `X-Hooky-App: <bundle id> <version> (<build>)` (also as `client` and `app` parameters on the WebSocket).
- The conversation's token is kept in the Keychain (this device only, after first unlock), per site key. The unsent draft and the last message seen are kept in `UserDefaults`.
- Nothing else is collected: the same data as the web bubble (messages, files, the optional name and email, language and time zone so the team replies in the right language and at the right hour).

## Behavior

- Live replies over Action Cable; "typing…" and "Read" like the web bubble. The connection closes when the app goes to the background and reopens (catching up) when it returns, with growing reconnection delays (1 s to 30 s).
- Links in messages are tappable; a message of 1 to 3 emoji is shown large.
- Clear error messages (offline, file too large, too many files, rate limited) in the user's language.
- The draft survives closing the conversation and relaunching the app.
- VoiceOver labels on every control, Dynamic Type everywhere, the keyboard never hides the input.

## Example app

`Exemple/` is a small SwiftUI app using the package by local path. Open `Exemple/HookyExemple.xcodeproj` (generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen)), set your key in `Config.siteKey` or in the scheme's environment variables (`HOOKY_SITE_KEY`, `HOOKY_API_URL`, `HOOKY_LANG`, `HOOKY_RESET=1`), and run.

## Tests

```sh
xcodebuild test -scheme Hooky -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The example's UI tests (`Exemple/HookyExempleUITests`) run the whole journey against a Hooky server: first message with a photo, the team's live reply, the unread badge, the conversation resumed after a relaunch. See the comment at the top of `ParcoursUITests.swift`.
