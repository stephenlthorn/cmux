import AppKit
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextServer
import Foundation

/// The one-line join in the app (Labs `labs.machineJoin`): each call is one short run of the bundled
/// `cmux` CLI (`machine add|list|doctor`), handed the signed-in account's cmux access token on stdin
/// (`--cloud-token-stdin`), never in argv, the environment or a log. The card shows the app's own
/// words for a failure, never the CLI's stderr.
extension MachineJoinService {
    static func app(_ services: AppServices) -> MachineJoinService {
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment))
            .map { HostCLI(binary: $0, environment: SSHService.environment) }
        let auth = services.cloud.auth
        let token: @Sendable () async -> String? = { @MainActor in
            guard auth.isSignedIn else { return nil }
            return try? await auth.tokens().access
        }
        let machines = services.machines
        // Every successful list read feeds the Machines section too (Add Device's flip shows the row).
        let store = { @MainActor [weak services] (rows: [JoinedMachine]) in services?.joinedMachines.apply(rows) }
        return MachineJoinService(
            mint: { name in
                guard let cli else { return .failure(.failed) }
                guard let access = await token() else { return .failure(.signedOut) }
                let arguments = ["machine", "add", "--json", "--no-wait", "--cloud-token-stdin"] + (name.map { ["--name", $0] } ?? [])
                guard let run = await cli.run(arguments, secret: access, label: "machine add") else { return .failure(.failed) }
                if run.status == 0 { return JoinLine.decode(Data(run.stdout.utf8)).map(Result.success) ?? .failure(.failed) }
                return .failure(Self.unavailable(run) ? .unavailable : .failed)
            },
            list: {
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "list", "--json", "--cloud-token-stdin"], secret: access, label: "machine list"),
                      run.status == 0, let rows = JoinedMachine.list(from: Data(run.stdout.utf8)) else { return nil }
                await store(rows)
                return rows
            },
            doctor: { id in
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "doctor", id, "--json", "--cloud-token-stdin"], secret: access,
                                              deadline: .seconds(30), label: "machine doctor") else { return [] }
                return MachineJoinService.steps(run.stdout)
            },
            // A machine connecting or leaving is the mesh change the app sees; the first value
            // (the list as it is now) is not a change.
            meshChanges: {
                AsyncStream { continuation in
                    // task-owner: ends when the card's watch stops (the stream's termination cancels it).
                    let follow = Task { @MainActor in
                        var first = true
                        for await _ in ObservationStream({ machines.daemons.map(\.machineID) }) {
                            if first { first = false; continue }
                            continuation.yield()
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in follow.cancel() }
                }
            },
            revoke: { id in
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "revoke", id, "--yes", "--json", "--cloud-token-stdin"], secret: access,
                                              label: "machine revoke") else { return false }
                return run.status == 0
            },
            // Its output may carry the new credential: only the status is read.
            rotate: { id in
                guard let cli, let access = await token(),
                      let run = await cli.run(["machine", "rotate", id, "--json", "--cloud-token-stdin"], secret: access,
                                              label: "machine rotate") else { return false }
                return run.status == 0
            })
    }

    /// The platform does not serve the join here (404 `machine.not_found`), or this cmux has no
    /// `machine add` mint yet (an unknown flag).
    private nonisolated static func unavailable(_ run: SSHProcessResult) -> Bool {
        let text = run.stderr.lowercased()
        return text.contains("not_found") || text.contains("404") || text.contains("unexpected argument") || text.contains("unknown")
    }
}
