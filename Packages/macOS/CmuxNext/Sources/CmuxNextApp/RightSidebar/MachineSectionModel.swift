import CmuxNextServer

extension MachineSectionModel {
    /// The rows of `machines` now, each with its last check from `health`, then the machines that
    /// joined with a one-line token (`joined`, empty while Labs `labs.machineJoin` is off) that the
    /// app does not already connect to.
    static func rows(_ machines: MachineRegistry, health: MachineHealthStore, joined: JoinedMachineStore? = nil) -> [MachineSectionRow] {
        let connected = machines.daemons.map { daemon in
            let connected = if case .connected = daemon.store.connectionState { true } else { false }
            let name = daemon.isLocal ? RightSidebarStrings.thisMac : machines.machineName(daemon.machineID) ?? daemon.machineID
            let report = health.reports[daemon.machineID]
            return MachineSectionRow(id: daemon.machineID, name: name, isConnected: connected, isLocal: daemon.isLocal,
                                     health: report?.health, healthStep: report?.worstStep?.step)
        }
        let known = Set(machines.daemons.map(\.machineID))
        let mesh = (joined?.machines ?? []).filter { $0.meshPeerId.map { !known.contains($0) } ?? true }
        return connected + mesh.map { MachineSectionRow.joined($0, health: health.reports[JoinedMachine.healthID($0.id)]) }
    }
}
