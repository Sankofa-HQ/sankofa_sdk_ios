# Sankofa iOS SDK 🚀

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/Platform-iOS%2013%2B-blue)](https://developer.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Sankofa](https://img.shields.io/badge/Made%20with-Sankofa-blueviolet)](https://sankofa.dev)

The official native iOS SDK for [Sankofa](https://sankofa.dev). Six products in one Swift framework: Analytics, Catch (Crashlytics + Sentry merged), Switch, Config, Pulse, Replay. Built entirely in Swift — no Objective-C, no swizzling, no UIKit injection.

---

## ✨ Features

- **Analytics** — events, identify, peopleSet. SQLite-backed (GRDB) offline-first queue.
- **Catch** — `NSSetUncaughtExceptionHandler`, POSIX signal handlers (SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGSYS), and a **main-queue stall detector** auto-installed by `Sankofa.shared.initialize`. Sentry-style `withScope` + `beforeSend` hooks.
- **Switch** — feature flags with bundled defaults, onChange listeners, halt webhook support.
- **Config** — remote-config with typed accessors.
- **Pulse** — in-app surveys.
- **Session Replay** — wireframe + screenshot modes (Ghost Masking), automatic input masking, `view.sankofaMask = true`. **SwiftUI-aware** scroll-offset tagging via `Sankofa.shared.tagScrollContainer { ... }`.
- **App Store Ready** — bundles `PrivacyInfo.xcprivacy`, no method swizzling.

---

## 🚀 Quick Start

### 1. Install via Swift Package Manager

In Xcode: **File → Add Package Dependencies…**

```
https://github.com/Sankofa-HQ/sankofa_sdk_ios
```

Or add to your `Package.swift`:

```swift
.package(url: "https://github.com/Sankofa-HQ/sankofa_sdk_ios.git", from: "1.0.0")
```

### 2. Initialize

One line. Catch auto-installs alongside analytics — no separate `SankofaCatch.shared.start(...)` call needed.

```swift
import SankofaIOS

@main
struct MyApp: App {
    init() {
        let config = SankofaConfig(
            endpoint: "https://api.sankofa.dev",
            recordSessions: true,
            maskAllInputs: true,
            catchEnvironment: "production",
            release: "myapp@1.4.0",
            appVersion: "1.4.0",
            catchStallThresholdSeconds: 2.0  // main-queue stall threshold (0 disables)
        )
        // Optional Sentry-style hook.
        config.beforeSend = { event in
            if event.message?.contains("[noise]") == true { return nil }
            return event
        }
        Sankofa.shared.initialize(apiKey: "YOUR_PROJECT_API_KEY", config: config)
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

---

## 🛠 Usage

### Analytics

```swift
Sankofa.shared.track("purchase_completed", properties: [
    "item_id": "cam_001",
    "price": 120.50,
])

Sankofa.shared.identify(userId: "user_99")
Sankofa.shared.setPerson(
    name: "Jane Doe",
    email: "jane@example.com",
    properties: ["plan": "pro"]
)
```

### Catch — Crashlytics + Sentry merged

Static helpers work from anywhere — no instance to thread through.

```swift
// Capture a handled error
do {
    try chargeCard(amount)
} catch {
    Sankofa.captureException(error)
}

// Crashlytics-style breadcrumb log — rides on next capture, doesn't bill.
Sankofa.log("checkout: applying coupon SUMMER25")

// Ambient context
Sankofa.setUser(CatchUserContext(id: "u_42", email: "ada@example.com"))
Sankofa.setTag("flow", "checkout")
Sankofa.setExtra("cart_id", AnyCodable(cart.id))

// Sentry-style temporary scope
Sankofa.withScope { scope in
    scope.setTag("checkout_step", "payment")
    scope.setLevel(.warning)
    Sankofa.captureException(err)
}
```

### SwiftUI scroll-offset tagging

UIKit scroll containers work automatically. For custom hosts / `LazyVGrid` / pre-iOS 16 SwiftUI, register a provider:

```swift
struct ProductList: View {
    @State private var scrollOffset: CGFloat = 0
    @State private var handle: SankofaScrollContainerHandle?

    var body: some View {
        ScrollView {
            // ... content with a GeometryReader feeding scrollOffset
        }
        .onAppear { handle = Sankofa.shared.tagScrollContainer { scrollOffset } }
        .onDisappear { handle?.remove() }
    }
}
```

### Session Replay — masking

```swift
mySecretView.sankofaMask = true  // Auto-masks this view in replays
```

---

## 🛠 Configuration Reference

| Option | Default | Description |
|---|---|---|
| `endpoint` | `https://api.sankofa.dev` | Your Sankofa engine base URL |
| `debug` | `false` | Verbose console output |
| `trackLifecycleEvents` | `true` | Auto-track app open / foregrounded / backgrounded |
| `flushIntervalSeconds` | `30` | Foreground flush cadence |
| `batchSize` | `50` | Events buffered before early flush |
| `recordSessions` | `true` | Enable session replay |
| `maskAllInputs` | `true` | Auto-mask all `UITextField` / `UITextView` |
| `captureScale` | `0.35` | Replay screenshot resolution |
| `enableCatch` | `true` | Auto-install Catch + NSException + signals + stall detector |
| `catchEnvironment` | `"live"` | Environment tag on every Catch event |
| `release` | `nil` | Release identifier (e.g. `"myapp@1.4.0"`) |
| `appVersion` | `nil` | App-version override for Catch device context |
| `beforeSend` | `nil` | Sentry-style hook; return `nil` to drop |
| `catchStallThresholdSeconds` | `2.0` | Main-queue stall threshold (0 disables) |

---

## 📑 API Reference

| Method | Description |
|---|---|
| `Sankofa.shared.initialize(apiKey:config:)` | Initialize SDK + Catch + signal handlers + stall detector. |
| `Sankofa.shared.track(_:properties:)` | Track a custom event. |
| `Sankofa.shared.identify(userId:)` | Link anonymous → known user. |
| `Sankofa.shared.setPerson(...)` | Set profile attributes. |
| `Sankofa.shared.reset()` | Clear identity + rotate session. |
| `Sankofa.shared.flush()` | Force-upload queued events. |
| `Sankofa.captureException(_:)` | Capture a handled error (static). |
| `Sankofa.captureMessage(_:)` | Non-error event. |
| `Sankofa.log(_:[category:])` | Crashlytics-style breadcrumb. |
| `Sankofa.setUser` / `setTag` / `setTags` / `setExtra` / `addBreadcrumb` | Ambient context. |
| `Sankofa.withScope { scope in ... }` | Temporary scope overlay. |
| `Sankofa.flushCatch()` | Force-flush Catch events. |
| `Sankofa.shared.tagScrollContainer { offset }` | Register a SwiftUI / custom scroll-offset provider. |

---

## 🛡 Privacy & App Store

- **No Objective-C swizzling** — lifecycle tracking uses `NotificationCenter`.
- **Includes `PrivacyInfo.xcprivacy`** — required for App Store submission since Spring 2024.
- **Ghost Masking** — screenshot mode never injects views or touches the live UI hierarchy.

---

## 📑 Documentation

Full API reference and integration guides: [docs.sankofa.dev/sdks/ios](https://docs.sankofa.dev/sdks/ios/overview).

---

## 📄 License

MIT — see `LICENSE` for details.
