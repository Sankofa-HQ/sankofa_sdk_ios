import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Live-presence heartbeat — every ~15s while the app is foregrounded
/// the SDK pings `/api/v1/screens/heartbeat` so the dashboard's
/// "X live now" badge reflects who's actually on each screen.
///
/// Mirrors the web + RN implementations: app-state replaces document
/// visibility. Backgrounded apps stop ticking immediately so we don't
/// paint stale "still live" badges for users who minimised the app.
/// Resuming foreground sends one immediate heartbeat so the badge
/// updates the instant they return.
///
/// Server-side TTL handles the rest — a missed heartbeat just trims
/// the user from the live set after the window. Presence is decorative;
/// failures are silent.
final class SankofaPresenceHeartbeat {
    private let url: URL
    private let apiKey: String
    private let session: URLSession
    private let intervalSeconds: TimeInterval = 15
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.sankofa.presence", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    /// Provider so the heartbeat asks the live SDK for the active screen
    /// each tick instead of caching it. Identity / screen change between
    /// ticks otherwise wouldn't be reflected.
    private let payloadProvider: () -> (screen: String?, distinctId: String?, sessionId: String?)

    init?(endpoint: String, apiKey: String,
          payloadProvider: @escaping () -> (screen: String?, distinctId: String?, sessionId: String?)) {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/api/v1/screens/heartbeat") else { return nil }
        self.url = url
        self.apiKey = apiKey
        self.payloadProvider = payloadProvider

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: cfg)
    }

    func start() {
        // Prime once so the dashboard sees the user the moment the app
        // launches, not 15s later.
        beat()

        #if canImport(UIKit)
        let center = NotificationCenter.default
        let active = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Resumed foreground — fire immediately, then resume the
            // timer.
            self?.beat()
            self?.scheduleTimer()
        }
        let inactive = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cancelTimer()
        }
        observers = [active, inactive]
        #endif

        scheduleTimer()
    }

    func stop() {
        cancelTimer()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func scheduleTimer() {
        cancelTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
        t.setEventHandler { [weak self] in self?.beat() }
        t.resume()
        timer = t
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func beat() {
        let payload = payloadProvider()
        guard let screen = payload.screen, !screen.isEmpty else { return }
        guard let distinctId = payload.distinctId, !distinctId.isEmpty else { return }

        var body: [String: Any] = [
            "screen": screen,
            "distinct_id": distinctId,
        ]
        if let sid = payload.sessionId, !sid.isEmpty {
            body["session_id"] = sid
        }
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: []) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = json

        // Fire-and-forget — presence is decorative, never block the
        // SDK on a failed ping.
        let task = session.dataTask(with: req) { _, _, _ in /* swallow */ }
        task.resume()
    }
}
