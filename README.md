# Hooky for iOS

A native chat between your users and your team, in three lines. The conversation is built with SwiftUI (no web view), follows the device's language, dark mode and Dynamic Type, and works from SwiftUI and UIKit apps.

- iOS 15+ and Mac Catalyst 15+
- Swift 6, strict concurrency
- No third-party dependency (URLSession, URLSessionWebSocketTask, PhotosUI, Keychain)
- MIT license

## Installation

Swift Package Manager, from GitHub: in Xcode, **File › Add Package Dependencies…**, paste

```
https://github.com/Defdjamel/hooky-ios
```

and pick **Up to Next Major Version** from `1.0.0`. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Defdjamel/hooky-ios", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Hooky", package: "hooky-ios")]),
]
```

The package ships its privacy manifest (`PrivacyInfo.xcprivacy`), which Xcode merges into your app's privacy report.

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
| `Hooky.configure(siteKey:apiURL:language:translation:)` | Starts the SDK: loads the site's name, color and greeting, resumes the saved conversation and opens the live connection. `apiURL` is for tests against your own server (default `https://api.heyhooky.com`); `language` forces `fr`, `en`, `es`, `pt`, `it` or `de` (the device language otherwise, English by default); `translation: false` hides the translation of the team's messages (on by default). |
| `Hooky.identify(name:email:userId:attributes:)` | Optional. Who the user is: name, email, your own user id and free data (see [Identify your users](#identify-your-users)). With an email, the chat skips its name and email form. |
| `Hooky.setAttributes(_:)` | Adds free data about the user (`["plan": "Pro", "cart": 49.9]`), merged with the previous; `nil` removes a key. |
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

### Identify your users

When your user signs in, tell Hooky who they are. Your team sees it on the conversation: name, email, your user id, the device, and the free data.

```swift
Hooky.identify(
    name: "Lila",
    email: "lila@example.com",
    userId: "42",                                   // your own id for this user
    attributes: ["plan": "Pro", "cart": 49.9, "beta": true]
)

Hooky.setAttributes(["cart": 12, "last_screen": "Checkout"])   // later, merged
Hooky.setAttributes(["beta": nil])                             // removes a key

Hooky.reset()                                       // when the user signs out
```

- Before the first message, everything is kept in memory and sent with it. Once a conversation exists, changes are sent right away, grouped (one request for all the changes made within a second). Nothing throws: offline, they are retried with the next message or when the app comes back.
- `name` and `email` replace the conversation's; `userId: nil` leaves it unchanged.
- The `userId` is kept with the conversation's token. If `identify` gives a **different** `userId`, the conversation is forgotten (like `reset()`): another account on the same device never sees the previous one's thread.
- Free data: a flat object, up to 50 keys (letters, digits, spaces, `_`, `.`, `-`; 64 characters max), values are strings (500 characters max), numbers or booleans. The server cleans the rest, it never refuses a message for it. The user id is a hint for your team, not verified.

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

## Translation

When your team writes in another language than the chat's (`language`, or the device's), a discreet **Translate** link sits under the message. Translated, the message shows the text in the user's language with "Translated from English · See original" (a toggle). The translate button in the conversation's header offers **Always translate**: the team's messages then arrive translated, still with "See original". The setting is remembered on the device, per site key. Translations are kept in memory for the conversation (and by the server, so asking again costs nothing); a failed translation shows a short error with "Try again". The user's own messages are never translated.

It needs a Hooky server that tells each message's language: with an older one, no link appears. To turn it off: `Hooky.configure(siteKey: "…", translation: false)`.

## What the SDK sends and stores

- Every request carries `X-Hooky-Client: hooky-ios/<SDK version>` and `X-Hooky-App: <bundle id> <version> (<build>)` (also as `client` and `app` parameters on the WebSocket).
- The conversation's token is kept in the Keychain (this device only, after first unlock), per site key, with the `userId` given to `identify`. The unsent draft, the last message seen and the "Always translate" setting are kept in `UserDefaults`.
- The device, readable: `iPhone 15 Pro · iOS 18.2`, `iPad Air 11-inch (M2) · iPadOS 18.1`, `Mac · macOS 15.1` (a model newer than the SDK shows as its identifier, like `iPhone19,1`).
- Nothing else is collected: the same data as the web bubble (messages, files, the optional name and email, language and time zone so the team replies in the right language and at the right hour), plus what you pass to `identify` and `setAttributes`. A translation sends only the message's id and the chat's language.

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

## License

MIT, see [LICENSE](LICENSE).
