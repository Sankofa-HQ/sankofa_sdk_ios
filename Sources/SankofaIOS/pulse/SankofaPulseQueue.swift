import Foundation

/// Persistent queue for offline survey submissions.
///
/// Lightweight on purpose: we serialise SankofaPulseSubmitPayload
/// envelopes to a JSON file in the SDK's library directory and
/// retry on next foreground. Heavyweight ordering / dedup isn't
/// needed — the server's `pulse_response_partials` table is the
/// canonical "in-flight response" surface for editors.
///
/// Unlike SankofaQueueManager (which handles hundreds of analytics
/// events/sec) this queue is small — typical survey volume is a
/// few completions per session, so a single-file JSONL store is
/// adequate. If volumes grow we'd switch to GRDB like the events
/// queue uses.
@available(iOS 13.0, macOS 10.15, *)
public actor SankofaPulseQueue {

    private let storeURL: URL
    private var pending: [SankofaPulseSubmitPayload]

    public init(storeURL: URL) {
        self.storeURL = storeURL
        self.pending = Self.loadFromDisk(storeURL)
    }

    public var count: Int { pending.count }

    public func enqueue(_ payload: SankofaPulseSubmitPayload) {
        pending.append(payload)
        persist()
    }

    /// Drain attempts to flush every pending payload through the
    /// supplied submit function. Successes are removed; failures
    /// stay in the queue and surface in the returned tally.
    @discardableResult
    public func drain(
        submit: (SankofaPulseSubmitPayload) async throws -> SankofaPulseSubmitResponse
    ) async -> (sent: Int, failed: Int) {
        var sent = 0
        var failed = 0
        var remaining: [SankofaPulseSubmitPayload] = []
        for payload in pending {
            do {
                _ = try await submit(payload)
                sent += 1
            } catch {
                failed += 1
                remaining.append(payload)
            }
        }
        pending = remaining
        persist()
        return (sent, failed)
    }

    /// Clears the queue. Test surface; ops shouldn't ever need this.
    public func clear() {
        pending.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(pending)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Disk write failed — likely a sandbox / quota issue.
            // We keep the in-memory queue so the next attempt during
            // this session can succeed; on app death we lose the
            // unflushed payloads. This trades a worst-case data
            // loss for not crashing the host on disk-full.
        }
    }

    private static func loadFromDisk(_ url: URL) -> [SankofaPulseSubmitPayload] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SankofaPulseSubmitPayload].self, from: data)) ?? []
    }

    public static func defaultStoreURL() -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(
            for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = dir.appendingPathComponent("Sankofa", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("pulse-queue.json")
    }
}
