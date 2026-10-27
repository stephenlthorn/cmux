import Darwin
import Foundation
import os

/// Runs a short command through the user's login shell with a hard deadline.
public struct MobileTaskModelShellRunner: Sendable {
    private let shellPath: String

    /// Creates a login-shell command runner.
    ///
    /// - Parameter shellPath: Absolute shell path, normally `$SHELL` or `/bin/zsh`.
    public init(shellPath: String) {
        self.shellPath = shellPath
    }

    /// Runs a command and captures UTF-8 standard output.
    ///
    /// A readability handler drains the pipe, so no thread blocks on it: the
    /// call finishes at end-of-file after the shell exits, or at the deadline,
    /// whichever comes first. A descendant that inherited standard output
    /// (`(sleep 10) & echo hi`) can no longer hold the caller past `timeout`.
    ///
    /// At the deadline a cancellable clock task sends `SIGKILL` to the shell's
    /// process group when the shell leads one, otherwise to the shell alone,
    /// and only while the shell has not exited, so a reaped PID is never
    /// signaled. Descendants of a shell that already exited, or that left its
    /// group, may linger but do not delay the result.
    ///
    /// - Parameters:
    ///   - command: Static command text passed to the login shell with `-lc`.
    ///   - timeout: Hard execution deadline.
    /// - Returns: Standard output on a zero exit before the deadline, otherwise `nil`.
    public func run(command: String, timeout: Duration) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = ["-lc", command]
            let outputPipe = Pipe()
            let output = outputPipe.fileHandleForReading
            let run = MobileTaskModelShellRun()
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { run.exited(status: $0.terminationStatus) }
            output.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    run.reachedEndOfFile()
                } else {
                    run.append(chunk)
                }
            }
            do {
                try process.run()
            } catch {
                output.readabilityHandler = nil
                return nil
            }

            run.started(processID: process.processIdentifier)
            let timeoutTask = Task.detached(priority: .utility) {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return
                }
                run.expire()
            }
            let data = await run.waitForResult()
            timeoutTask.cancel()
            output.readabilityHandler = nil
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }.value
    }
}

/// Output buffer and one-shot completion gate shared by one run's handlers.
///
/// The run settles exactly once: at end-of-file after the shell exited, or at
/// the deadline. The later event is a no-op, so the waiter resumes once.
private final class MobileTaskModelShellRun: Sendable {
    private typealias Waiter = CheckedContinuation<Data?, Never>

    private struct State: Sendable {
        var output = Data()
        var processID: pid_t = 0
        var signalsGroup = false
        var exitStatus: Int32?
        var reachedEndOfFile = false
        var isSettled = false
        var result: Data?
        var waiter: Waiter?

        mutating func settle(_ value: Data?) -> Waiter? {
            guard !isSettled else { return nil }
            isSettled = true
            result = value
            defer { waiter = nil }
            return waiter
        }

        mutating func settleIfComplete() -> Waiter? {
            guard reachedEndOfFile, let exitStatus else { return nil }
            return settle(exitStatus == 0 ? output : nil)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func started(processID: pid_t) {
        // `Process` normally spawns the shell as its own group leader, and a
        // non-interactive shell keeps background jobs in that group. If it
        // did not, the group is the caller's own and must not be signaled.
        let leadsGroup = getpgid(processID) == processID && processID != getpgrp()
        state.withLock {
            $0.processID = processID
            $0.signalsGroup = leadsGroup
        }
    }

    func append(_ chunk: Data) {
        state.withLock { $0.output.append(chunk) }
    }

    func reachedEndOfFile() {
        let (waiter, result) = state.withLock { state in
            state.reachedEndOfFile = true
            return (state.settleIfComplete(), state.result)
        }
        waiter?.resume(returning: result)
    }

    func exited(status: Int32) {
        let (waiter, result) = state.withLock { state in
            state.exitStatus = status
            return (state.settleIfComplete(), state.result)
        }
        waiter?.resume(returning: result)
    }

    func expire() {
        let waiter = state.withLock { state -> Waiter? in
            guard !state.isSettled else { return nil }
            // A recorded exit means Foundation already reaped the PID, which
            // could now belong to an unrelated process.
            if state.exitStatus == nil, state.processID > 0 {
                if state.signalsGroup {
                    _ = Darwin.killpg(state.processID, SIGKILL)
                } else {
                    _ = Darwin.kill(state.processID, SIGKILL)
                }
            }
            return state.settle(nil)
        }
        waiter?.resume(returning: nil)
    }

    func waitForResult() async -> Data? {
        await withCheckedContinuation { continuation in
            let settled = state.withLock { state -> (Bool, Data?) in
                if state.isSettled {
                    return (true, state.result)
                }
                state.waiter = continuation
                return (false, nil)
            }
            if settled.0 {
                continuation.resume(returning: settled.1)
            }
        }
    }
}
