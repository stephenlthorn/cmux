import AppKit
@testable import CmuxNextServer
import Foundation
import SwiftUI
import Testing

/// The Machines section's joined machines (Labs `labs.machineJoin`): rows from `cmux machine list`
/// (none while the switch is off), Revoke and Rotate through the CLI and a fresh read after, Check
/// as the Check Machine checklist on `machine doctor ID`, and the "…" menu's items.
@MainActor @Suite(.serialized) struct JoinedMachineRowsTests {
    final class Fake: @unchecked Sendable {
        var rows: [JoinedMachine] = [Fake.machine("m_1", "lane-vm-3")]
        var lists = 0
        var revoked: [String] = []
        var rotated: [String] = []
        var answer = true
        var on = true

        func store() -> JoinedMachineStore {
            JoinedMachineStore(service: { [self] in
                guard on else { return nil }
                return MachineJoinService(
                    mint: { _ in .failure(.failed) },
                    list: { [self] in lists += 1; return rows },
                    revoke: { [self] id in
                        revoked.append(id)
                        if answer { rows = rows.map { $0.id == id ? Fake.machine(id, $0.name, state: .revoked) : $0 } }
                        return answer
                    },
                    rotate: { [self] id in rotated.append(id); return answer })
            })
        }

        static func machine(_ id: String, _ name: String, state: JoinedMachine.State = .online, mesh: String? = nil) -> JoinedMachine {
            JoinedMachine(id: id, name: name, state: state, platform: "linux", meshPeerId: mesh, joinTokenId: "jt_\(id)", mintedBy: "you@example.com")
        }
    }

    @Test func theStoreListsNothingWhileTheLabsSwitchIsOff() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        #expect(store.machines.map(\.id) == ["m_1"])
        fake.on = false
        await store.refresh()
        #expect(store.machines.isEmpty, "turning the switch off empties the section's joined rows")
        #expect(fake.lists == 1)
    }

    @Test func aRefreshIsOneReadAndAFailedReadKeepsTheRows() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        #expect(fake.lists == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.lists == 1, "no timer reads the list")
        let failing = JoinedMachineStore(service: {
            MachineJoinService(mint: { _ in .failure(.failed) }, list: { nil })
        })
        failing.apply(store.machines)
        await failing.refresh()
        #expect(failing.machines.map(\.id) == ["m_1"])
    }

    @Test func revokeRunsTheCLIAndTheRowTurnsRevoked() async {
        let fake = Fake()
        let store = fake.store()
        await store.refresh()
        let ok = await store.perform(.revoke, "m_1")
        #expect(ok)
        #expect(fake.revoked == ["m_1"])
        #expect(fake.lists == 2, "the list is read again after the revoke")
        #expect(store.machines.first?.state == .revoked)
        #expect(store.busy.isEmpty)
        #expect(store.failed.isEmpty)
    }

    @Test func aRefusedRotateSaysSoOnTheRow() async {
        let fake = Fake()
        fake.answer = false
        let store = fake.store()
        await store.refresh()
        #expect(!(await store.perform(.rotate, "m_1")))
        #expect(fake.rotated == ["m_1"])
        #expect(store.failed["m_1"] == .rotate)
        let caption = JoinedMachineStrings.caption(store.machines[0], failed: store.failed["m_1"])
        #expect(caption.contains("rotate"), "the row's caption says the rotate failed: \(caption)")
    }

    @Test func joinedRowsFollowTheConnectedOnesAndCarryWhoMadeTheirLine() {
        let health = MachineHealthStore()
        let online = Fake.machine("m_1", "lane-vm-3")
        let revoked = Fake.machine("m_2", "old-box", state: .revoked)
        let row = MachineSectionRow.joined(online, health: health.reports[JoinedMachine.healthID("m_1")])
        #expect(row.id == "joined:m_1")
        #expect(row.isConnected)
        #expect(row.joined?.mintedBy == "you@example.com")
        #expect(JoinedMachineStrings.caption(online, failed: nil) == "Online · added by you@example.com")
        #expect(!MachineSectionRow.joined(revoked, health: nil).isConnected)
        #expect(JoinedMachineStrings.caption(revoked, failed: nil).hasPrefix("Revoked"))
    }

    @Test func theMenuOffersCheckRotateAndRevokeAndARevokedMachineOnlyCheck() {
        let menu = JoinedMachineMenu.make(Fake.machine("m_1", "lane-vm-3"), busy: false) { _, _ in }
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["Check", "Rotate Credential", "Revoke…"])
        #expect(items.allSatisfy(\.isEnabled))
        let gone = JoinedMachineMenu.make(Fake.machine("m_2", "old-box", state: .revoked), busy: false) { _, _ in }
        #expect(gone.items.filter { !$0.isSeparatorItem }.map(\.isEnabled) == [true, false, false])
        let busy = JoinedMachineMenu.make(Fake.machine("m_1", "lane-vm-3"), busy: true) { _, _ in }
        #expect(busy.items.allSatisfy { $0.isSeparatorItem || !$0.isEnabled })
    }

    @Test func aMenuItemRunsItsAction() throws {
        var ran: [(JoinedMachineAction, String)] = []
        let menu = JoinedMachineMenu.make(Fake.machine("m_1", "lane-vm-3"), busy: false) { ran.append(($0, $1.id)) }
        let rotate = try #require(menu.items.first { $0.title == "Rotate Credential" })
        menu.performActionForItem(at: menu.index(of: rotate))
        #expect(ran.map(\.0) == [.rotate])
        #expect(ran.map(\.1) == ["m_1"])
    }

    @Test func revokeAsksWithTheHeartbeatBound() {
        #expect(JoinedMachineStrings.revokeTitle("lane-vm-3") == "Revoke lane-vm-3?")
        #expect(JoinedMachineStrings.revokeBody.contains("\(JoinedMachineStrings.heartbeatSecondsPlaceholder) seconds"))
    }

    @Test func checkRunsMachineDoctorWithTheAccountOnStdinAndOffersNoFix() async {
        let host = AddMachineFlowTests.FakeHost()
        let doctor = [AddMachineFlowTests.step("listed", "ok"), AddMachineFlowTests.step("heartbeat", "fail", "last seen 9 min ago",
                                                                                         fix: "Run cmux machine doctor on lane-vm-3")]
        host.scripts = [doctor + [AddMachineFlowTests.report("lane-vm-3", "m_1", ok: false, doctor)]]
        let model = AddMachineModel(services: host.services())
        model.beginJoinedCheck(id: "m_1", name: "lane-vm-3")
        _ = await model.finished()
        #expect(host.commands == [.joinedDoctor(id: "m_1")])
        #expect(HostCommand.joinedDoctor(id: "m_1").arguments == ["machine", "doctor", "m_1", "--json", "--cloud-token-stdin"])
        #expect(HostCommand.joinedDoctor(id: "m_1").needsAccount)
        #expect(!HostCommand.doctor(host: "h", fix: false).needsAccount)
        #expect(model.runName == "lane-vm-3")
        #expect(host.recorded.map(\.0) == ["joined:m_1"], "the row's mark follows the check")
        #expect(!model.buttons.map(\.action).contains(.fix), "the minting end fixes nothing on another machine")
        #expect(model.buttons.map(\.action) == [.copyDetails, .done])
    }

    /// The row and its menu as a picture: `Packages/macOS/CmuxNext/.build/machines-joined-rows.png`.
    @Test func theSectionWithJoinedRowsRenders() async throws {
        _ = NSApplication.shared
        let fake = Fake()
        fake.rows = [Fake.machine("m_1", "lane-vm-3"), Fake.machine("m_2", "gpu-west", state: .offline),
                     Fake.machine("m_3", "old-box", state: .revoked)]
        let store = fake.store()
        await store.refresh()
        let model = MachineSectionModel()
        let health = MachineHealthStore()
        model.update([MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true)]
            + store.machines.map { MachineSectionRow.joined($0, health: health.reports[JoinedMachine.healthID($0.id)]) })
        let view = NSHostingView(rootView: MachineSectionListView(model: model, newWorkspace: { _ in }, addMachine: {}, joinedStore: store))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        let image = try AddMachineShotsTests.render(view)
        #expect(image.size.height >= 120)
        let out = AddServerShotsTests.packageRoot.appending(path: ".build/machines-joined-rows.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AddServerShotsTests.png(AddServerShotsTests.contactSheet([("joined rows", image)])).write(to: out)
    }
}
