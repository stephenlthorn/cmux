import Foundation
import Testing
@testable import CmuxIrxTransport

/// A pre-hello step that never answers must not park the control-plane loop.
/// On 2026-10-27 a Mac's loop logged `reconnect-scheduled` after a dropped
/// socket and then went silent for 64 minutes: the token fetch or hello send
/// had no deadline, so no socket, no retry and no phone could reach the Mac.
@Suite struct IrxControlPlaneSetupTimeoutTests {
    private actor Calls {
        var count = 0
        func bump() -> Int { count += 1; return count }
    }

    /// A token fetch that ignores Swift cancellation (like the URLSession
    /// calls underneath), so a task-group timeout would wait on it forever.
    private final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock(); waiters.append(c); lock.unlock()
            }
        }
        func releaseAll() {
            lock.lock(); let w = waiters; waiters = []; lock.unlock()
            w.forEach { $0.resume() }
        }
    }

    private static func events(in url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["component"] as? String == "control-plane",
                  let event = object["event"] as? String else { return nil }
            if let phase = object["a_phase"] as? String { return "\(event):\(phase)" }
            return event
        }
    }

    @Test func hungTokenPairTimesOutAndRetries() async throws {
        let journalURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("irx-setup-timeout-\(UUID().uuidString).jsonl")
        let cache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("irx-setup-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: cache)
        }
        let calls = Calls()
        let stuck = Stuck()
        let client = IrxControlPlaneClient(
            configuration: .init(
                socketURL: URL(string: "wss://control.invalid/v1/control/socket")!,
                endpointIDHex: "00", wantPasses: false, cacheDirectory: cache),
            tokenPair: {
                _ = await calls.bump()
                // Never answers and ignores cancellation: the 2026-10-27 hang.
                await stuck.wait()
                return nil
            },
            handlers: .init(
                onRelayPasses: { _ in true }, onHintUpdate: { _, _ in true },
                onDirectory: { _ in true }, onSnapshotComplete: { _ in }),
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "setup-timeout",
                journalFileURL: journalURL),
            setupTimeout: .milliseconds(200)
        )
        await client.start()
        // One timeout (0.2 s) + the first backoff (1 s + up to 0.5 s jitter)
        // + the second attempt starting.
        let deadline = ContinuousClock.now + .seconds(5)
        while await calls.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        await client.stop()
        stuck.releaseAll()

        #expect(await calls.count >= 2, "the loop must try again after a hung token fetch")
        let events = Self.events(in: journalURL)
        #expect(events.contains("setup-timeout:token-pair"))
        #expect(events.contains("reconnect-scheduled"))
    }
}
