import Foundation
import UIKit

/// Uploads captured replay frames to the Sankofa backend.
///
/// Mirrors `SankofaReplayUploader` in the Flutter SDK.
/// Runs compression and upload on a background queue.
final class SankofaReplayUploader {

    private let queueManager: SankofaQueueManager
    private let logger: SankofaLogger
    private let uploadQueue = DispatchQueue(label: "dev.sankofa.replay.upload", qos: .utility)

    private var chunkIndex: Int = 0
    private var distinctId: String = "anonymous"

    /// Session id whose chunkIndex is currently in memory.  We rotate the
    /// counter and reload from `UserDefaults` whenever this changes — that
    /// way a session that survives a process kill (e.g. background relaunch
    /// before the session timeout fires) keeps its chunk numbering monotonic
    /// instead of re-emitting `chunk_index = 0` and producing a duplicate
    /// at the dashboard.  Mirrors Android's `SharedPreferences`-backed
    /// chunk-index counter.
    private var loadedSessionId: String = ""

    private static let chunkIndexKeyPrefix = "sankofa.replay.chunkIndex."

    init(queueManager: SankofaQueueManager, logger: SankofaLogger) {
        self.queueManager = queueManager
        self.logger = logger
    }

    func setDistinctId(_ id: String) {
        self.distinctId = id
    }

    /// Synchronises the in-memory `chunkIndex` with the persisted value
    /// for `sessionId`.  Called lazily from the upload path so we don't
    /// burn UserDefaults reads on every coordinator start when the
    /// session id hasn't actually changed.
    private func syncChunkIndex(forSessionId sessionId: String) {
        guard sessionId != loadedSessionId, !sessionId.isEmpty else { return }
        loadedSessionId = sessionId
        let key = Self.chunkIndexKeyPrefix + sessionId
        chunkIndex = UserDefaults.standard.integer(forKey: key)
    }

    func upload(_ frame: SankofaFrame, screenName: String = "Unknown", deviceContext: [String: Any]? = nil, interactions: [SankofaTouchInterceptor.Interaction] = [], scrollOffsetY: CGFloat = 0) {
        uploadQueue.async { [weak self] in
            guard let self else { return }

            // Lazy-load the persisted counter the first time we see a new
            // session id.  Subsequent calls in the same session take the
            // fast path (no UserDefaults read).  Persisted on every
            // increment so a process kill mid-upload still leaves the
            // next launch on the right index.
            self.syncChunkIndex(forSessionId: frame.sessionId)
            let currentChunk = self.chunkIndex
            self.chunkIndex += 1
            UserDefaults.standard.set(self.chunkIndex, forKey: Self.chunkIndexKeyPrefix + frame.sessionId)

            // 🚀 INTERACTION PROCESSING: Find the latest interaction for frame-level metadata.
            let latestInteraction = interactions.last
            
            // 📦 DYNAMIC PAYLOAD: Wrap in the dashboard-expected JSON schema.
            var envelope: [String: Any]
            let replayMode = "screenshot"
            
            // 🔥 App version for heatmap version partitioning
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

            switch frame.payload {
            case .screenshot(let data):
                envelope = [
                    "mode": "screenshot",
                    "$app_version": appVersion,
                    "frames": [[
                        "timestamp": Int64(frame.timestamp.timeIntervalSince1970 * 1000),
                        "image_base64": data.base64EncodedString(),
                        "screen": screenName,
                        "scroll_y": self.safeDouble(scrollOffsetY)
                    ]]
                ]
            }

            // Standard mobile metadata
            if let deviceContext {
                envelope["device_context"] = deviceContext
            }
            
            // Interaction list for ripples
            if !interactions.isEmpty {
                var events = envelope["events"] as? [[String: Any]] ?? []

                // 🚫 Drop interactions whose coordinates are NaN/Infinity.
                // UIKit can return non-finite values during edge cases like
                // device rotation mid-touch or detached gesture recognisers.
                // Previously we clipped to 0,0 via safeDouble — but that
                // plots a phantom dot at the top-left of the heatmap.
                // Skipping is safer: a single dropped touch is invisible,
                // a phantom (0,0) is misleading.
                let validInteractions = interactions.filter { i in
                    i.x.isFinite && i.absoluteY.isFinite
                }

                let interactionEvents: [[String: Any]] = validInteractions.map { i in
                    let type: Int
                    switch i.type {
                    case "pointer_down": type = 1    // 1 = MouseDown (rrweb MouseInteraction)
                    case "pointer_up":   type = 0    // 0 = MouseUp   (rrweb MouseInteraction)
                    case "pointer_move": type = 6    // 6 = TouchMove (rrweb MouseInteraction)
                    case "pinch":        type = 7    // 7 = Pinch/Zoom (midpoint tracking)
                    case "double_tap":   type = 4    // 4 = DblClick  (rrweb MouseInteraction)
                    default: type = 1
                    }
                    
                    // Send RAW CGFloat coordinates (UIKit points).
                    // x: viewport-relative (no scroll offset needed — horizontal scroll is rare)
                    // y: ABSOLUTE content position (viewport_y + scroll_offset_y).
                    //    This makes heatmap dots scroll-aware: a tap 300pt down while scrolled
                    //    200pt = absoluteY 500pt, placing the dot correctly on the full content map.
                    // The session replay player uses its own viewport-relative rendering and is unaffected.
                    //
                    // `screen` is intentionally a TOP-LEVEL field on the event (not on `data`).
                    // The replay worker reads `event.screen` for high-precision attribution
                    // when a chunk's interaction list spans a screen change — without it,
                    // taps captured before the user navigated would be mis-attributed to the
                    // FRAME's screen.  The `pendingCarryoverInteractions` bucket above
                    // routinely accumulates touches across multiple run-loop ticks, so this
                    // is a real bug pattern (not a theoretical one).
                    return [
                        "type": 3,
                        "data": [
                            "source": 2, // MouseInteraction
                            "type": type,
                            "id": 1,
                            "x": self.safeDouble(i.x),
                            "y": self.safeDouble(i.absoluteY)
                        ],
                        "timestamp": Int64(i.timestamp.timeIntervalSince1970 * 1000),
                        "screen": i.screen
                    ]
                }

                events.append(contentsOf: interactionEvents)
                envelope["events"] = events
            }

            // KILLER 2 (OOM Cleanup): Immediately encode and flush to SQLite, DO NOT hold in memory.
            // We tag it as 'replay_chunk' so the FlushManager knows where to send it.
            var finalPayload = envelope
            finalPayload["_distinct_id"] = self.distinctId
            finalPayload["_session_id"] = frame.sessionId
            finalPayload["_chunk_index"] = currentChunk
            finalPayload["_replay_mode"] = replayMode

            self.queueManager.enqueue(finalPayload, type: "replay_chunk")
            self.logger.log("📹 [v2] Frame queued (\(frame.sessionId)) chunk \(currentChunk)")
        }
    }

    private func safeDouble(_ value: CGFloat) -> Double {
        let d = Double(value)
        return d.isFinite ? d : 0.0
    }
}
