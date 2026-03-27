# Sankofa iOS SDK 🚀

[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/Platform-iOS%2014%2B-blue)](https://developer.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Sankofa](https://img.shields.io/badge/Made%20with-Sankofa-blueviolet)](https://sankofa.dev)

The official native iOS SDK for [Sankofa Analytics](https://sankofa.dev). Built entirely in Swift — no Objective-C, no swizzling, no UIKit injection.

---

## ✨ Features

- **Event Tracking** — Custom events with arbitrary properties and automatic device metadata.
- **Identity Management** — Resolve anonymous users to permanent profiles with `identify()` / `reset()`.
- **Offline-First Queue** — SQLite-backed event queue (GRDB.swift) survives app termination and network failures.
- **Dual-Engine Session Replay:**
  - **Wireframe Mode** *(Default)* — JSON view-tree, zero pixel data, ultra-low bandwidth.
  - **Screenshot Mode** — Pixel-perfect captures using **Ghost Masking** (CoreGraphics in-memory, zero UI flicker).
- **Escalation Triggers** — Switch Wireframe → Screenshot automatically on key user events via remote config.
- **Privacy First** — Auto-mask all `UITextField`/`UITextView`, manual masking via `.sankofaMask = true`.
- **App Store Ready** — Includes `PrivacyInfo.xcprivacy`. No method swizzling. Passes App Store Review.

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

In your `AppDelegate` or `@main` struct's entry point:

```swift
import SankofaIOS

@main
struct MyApp: App {
    init() {
        Sankofa.shared.initialize(
            apiKey: "YOUR_PROJECT_API_KEY",
            config: SankofaConfig(
                endpoint: "https://api.sankofa.dev",
                recordSessions: true,
                maskAllInputs: true
            )
        )
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

---

## 📈 Tracking Events

```swift
// Simple event
Sankofa.shared.track("onboarding_completed")

// Event with properties
Sankofa.shared.track("purchase_completed", properties: [
    "item_id": "cam_001",
    "price": 120.50,
    "currency": "USD"
])
```

---

## 👤 Identity & People

```swift
// On login — merges anonymous history with the known user
Sankofa.shared.identify(userId: "user_99")

// Set profile attributes
Sankofa.shared.setPerson(
    name: "Jane Doe",
    email: "jane@example.com",
    properties: ["plan": "pro"]
)

// On logout — clears identity and rotates the session
Sankofa.shared.reset()
```

---

## 🎥 Session Replay & Privacy

### Configuration

```swift
SankofaConfig(
    recordSessions: true,
    maskAllInputs: true,          // Auto-mask all UITextField / UITextView
    captureMode: .wireframe       // or .screenshot (Ghost Masking)
)
```

### Ghost Masking — How it Works

In Screenshot mode, Sankofa uses Apple's CoreGraphics to render the window into an **in-memory canvas**. Sensitive fields are blacked out in the image buffer **before** compression. The live screen is **never modified**.

> ⚡️ No UI injection. No subview overlays. No black flash. The user's screen remains smooth at all times.

### Manual Privacy Masking

```swift
import SankofaIOS

// Mark a view as sensitive (UIView extension)
mySecretView.sankofaMask = true

// From Interface Builder / XIB — set tag to 0x5A4B_0001
mySecretView.tag = 0x5A4B0001
```

---

## 🛠 Configuration Reference

| Option | Default | Description |
| :--- | :--- | :--- |
| `endpoint` | `https://api.sankofa.dev` | Your Sankofa engine base URL |
| `debug` | `false` | Enable verbose console output |
| `trackLifecycleEvents` | `true` | Auto-track `$app_opened/backgrounded/terminated` |
| `flushIntervalSeconds` | `30` | Event flush interval while foregrounded |
| `batchSize` | `50` | Events buffered before early flush |
| `recordSessions` | `true` | Enable session replay |
| `maskAllInputs` | `true` | Auto-mask all text inputs |
| `captureMode` | `.wireframe` | Replay engine (`.wireframe` or `.screenshot`) |

---

## 📑 API Reference

| Method | Description |
| :--- | :--- |
| `initialize(apiKey:config:)` | Initialise the SDK. Call once at app start. |
| `identify(userId:)` | Link anonymous session to a known user. |
| `track(_:properties:)` | Track a custom event. |
| `setPerson(name:email:properties:)` | Set profile attributes. |
| `reset()` | Clear identity and rotate session (call on logout). |
| `flush()` | Force-upload all queued events immediately. |

---

## 🏗 Architecture

```
SankofaIOS
├── Sankofa.swift                   # Public singleton entry point
├── SankofaConfig.swift             # Configuration struct
├── core/
│   ├── SankofaQueueManager.swift   # SQLite queue (GRDB.swift)
│   ├── SankofaFlushManager.swift   # URLSession batch dispatcher
│   ├── SankofaLifecycleObserver.swift  # NotificationCenter hooks
│   ├── SankofaIdentity.swift       # anonymous_id / distinct_id
│   ├── SankofaSessionManager.swift # session_id rotation
│   └── SankofaDeviceInfo.swift     # Device metadata enrichment
└── replay/
    ├── SankofaCaptureEngine.swift      # Protocol
    ├── SankofaCaptureCoordinator.swift # Strategy-pattern orchestrator
    ├── SankofaWireframeEngine.swift    # JSON view-tree engine
    ├── SankofaScreenshotEngine.swift   # Ghost Masking CoreGraphics engine
    ├── SankofaMask.swift               # UIView.sankofaMask extension
    └── SankofaReplayUploader.swift     # Chunked frame upload
```

---

## 🛡 Privacy & App Store

- **No Objective-C swizzling** — lifecycle tracking uses `NotificationCenter`.
- **Includes `PrivacyInfo.xcprivacy`** — required for App Store submission since Spring 2024.
- **Ghost Masking** — screenshot mode never injects views or touches the live UI hierarchy.

---

## 📄 License

MIT — see `LICENSE` for details.
