#if DEBUG
import CmuxNextActions
import CmuxNextServer
import CmuxNextSettings
import Foundation

/// `debug.joined_machines {menu?, check?}` (captures): the Machines section lists fixture joined
/// machines (online, offline, revoked) in place of `cmux machine list`, and shows the section.
/// `menu: true` marks the first row's menu open (its "…" button lit, as while its menu is up; a
/// window capture does not include the menu's own window). `check: true` opens Check on it with
/// fixture doctor lines. The fixture stays for the rest of the app's run, which a capture starts fresh.
@MainActor
enum DebugJoinedMachines {
    /// The joined machines' calls while set (``AppServices/joinedMachines``).
    static var service: MachineJoinService?

    nonisolated static let rows = [
        JoinedMachine(id: "m_lane", name: "lane-vm-3", state: .online, platform: "linux", hostname: "lane-vm-3",
                      joinTokenId: "jt_1", mintedBy: "you@example.com"),
        JoinedMachine(id: "m_gpu", name: "gpu-west", state: .offline, platform: "linux", joinTokenId: "jt_2", mintedBy: "sam@example.com"),
        JoinedMachine(id: "m_old", name: "old-box", state: .revoked, platform: "macos", joinTokenId: "jt_3"),
    ]

    /// `machine doctor` lines for the fixture's Check (HostStep JSON, then the report).
    static let doctorLines: [String] = {
        let steps = [("signed-in", "ok", ""), ("platform", "ok", ""), ("listed", "ok", ""),
                     ("heartbeat", "ok", "12 s ago"), ("mesh", "ok", "")]
        let lines = steps.map { #"{"step":"\#($0.0)","state":"\#($0.1)","detail":"\#($0.2)"}"# }
        let report = #"{"report":{"host":"m_lane","name":"lane-vm-3","ok":true,"steps":[\#(lines.joined(separator: ","))]}}"#
        return lines + [report]
    }()

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        // Only while labs.machineJoin is on, as the section itself.
        guard services.settings?.snapshot.machineJoin == true else {
            service = nil
            return .object(["machines": .number(0), "reason": .string("labs.machineJoin is off")])
        }
        service = MachineJoinService(mint: { _ in .failure(.unavailable) }, list: { rows })
        let store = services.joinedMachines
        store.apply(rows)
        _ = services.registry.perform("switchRightSidebarToMachines")
        store.openMenu = params["menu"]?.boolValue == true ? rows[0].id : nil
        if params["check"]?.boolValue == true {
            services.addMachine.checkJoined(id: rows[0].id, name: rows[0].name, over: services.windows.active?.window)
        }
        return .object(["machines": .number(Double(rows.count))])
    }
}
#endif
