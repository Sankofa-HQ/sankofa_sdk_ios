import Foundation

/// Sentry-style main-queue stall detector.
///
/// Periodically dispatches a sentinel block to the main queue from a
/// background timer. If the sentinel doesn't fire within
/// `thresholdSeconds`, the main queue is considered stalled and the
/// `onStall` callback fires once per stall event (de-duped so a
/// 30-second freeze produces one event, not thirty).
///
/// Why background-timer + main sentinel:
///   - A CADisplayLink / runloop observer ON the main queue can't
///     report a stall, because they're starved by the same wedge
///     they're trying to detect.
///   - A separate POSIX thread can read the main thread's stack but
///     can't synthesize a stall report inline — DispatchQueue.main is
///     the SDK's source of truth for "is the UI responsive".
///   - Sentry's approach is exactly this two-queue dance and it's
///     proven across millions of apps.
///
/// Phase D will add main-thread stack symbolication. For Phase B we
/// emit the event with the stall duration only, no stack body — the
/// dashboard surfaces "X% of sessions stalled" and the duration
/// distribution, which is the actionable signal.
final class CatchMainQueueStallDetector: @unchecked Sendable {
    private let thresholdSeconds: TimeInterval
    private let onStall: @Sendable (Double) -> Void
    private let monitorQueue: DispatchQueue
    private var timer: DispatchSourceTimer?

    // Atomic-ish state guarded by `lock`. `lastPingTimeMs` is when the
    // most recent sentinel was scheduled; `stallReported` is the dedup
    // flag — flipped TRUE when we report a stall, cleared back to
    // FALSE when the next sentinel fires.
    private let lock = NSLock()
    private var lastPingScheduledMs: Int64 = 0
    private var lastPingObservedMs: Int64 = 0
    private var stallReported: Bool = false
    private var stopped: Bool = false

    init(
        thresholdSeconds: TimeInterval,
        onStall: @escaping @Sendable (Double) -> Void
    ) {
        self.thresholdSeconds = thresholdSeconds
        self.onStall = onStall
        self.monitorQueue = DispatchQueue(label: "dev.sankofa.catch.stall", qos: .utility)
    }

    func start() {
        // Sample roughly every (threshold / 4) seconds — fine-grained
        // enough that a 2-second stall is reported within ~0.5s, coarse
        // enough that the background CPU cost is negligible.
        let interval = max(0.1, thresholdSeconds / 4.0)
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        // Prime the timestamps so the first tick doesn't immediately
        // report a stall.
        let now = nowMs()
        lock.lock()
        lastPingScheduledMs = now
        lastPingObservedMs = now
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let scheduledAt = nowMs()
        lock.lock()
        if stopped { lock.unlock(); return }
        let priorObserved = lastPingObservedMs
        let stallReportedNow = stallReported
        lastPingScheduledMs = scheduledAt
        lock.unlock()

        // Gap test — has the main queue serviced our PREVIOUS sentinel
        // within the threshold? Compare scheduled-time to the last
        // observed-on-main time. Sustained stalls keep `priorObserved`
        // stale; transient hitches don't.
        let gapMs = Double(scheduledAt - priorObserved)
        if gapMs >= thresholdSeconds * 1000.0 && !stallReportedNow {
            lock.lock()
            stallReported = true
            lock.unlock()
            onStall(gapMs)
        }

        // Schedule the next sentinel — when (and if) main services it,
        // it'll update `lastPingObservedMs` and clear the dedup flag.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let observedAt = self.nowMs()
            self.lock.lock()
            self.lastPingObservedMs = observedAt
            // Clear the dedup flag now that main is responsive again —
            // a subsequent stall will be reported as a fresh event.
            if self.stallReported {
                self.stallReported = false
            }
            self.lock.unlock()
        }
    }

    private func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}
