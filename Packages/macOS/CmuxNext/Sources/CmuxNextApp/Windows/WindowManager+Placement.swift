import CmuxNextActions
import CmuxNextBridge
import CmuxNextSidebar

/// A new workspace's sidebar slot, kept until the daemon reports it.
struct PendingPlacement {
    /// The window whose sidebar places it; nil: the window that lists it
    /// once reconcile gave it one (the most recent window).
    var window: String?
    var slot: WorkspaceSlot?
    /// `workspaces.newPlacement`, used when `slot` is nil.
    var byDefault: NewWorkspaceDefaultSlot?
    var then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)?
    /// The action run that asked for the placement: `then` runs later,
    /// outside its task, and keeps its view-change permission.
    var run: ActionRunScope? = ActionRunScope.current
    /// When it was asked for (`NewWorkspacePlacements.expect`): placements ready together go in that order.
    var sequence: UInt64 = 0
}

// Placing new workspaces (New Workspace Above/Below/at Top/Like This, a
// double-click in a group, and `workspaces.newPlacement` for every other new
// workspace): the slot is resolved against the window's sidebar only once
// the daemon reports the workspace, because the reorder plan needs it in the
// daemon's order. It then takes the row-drag path (`SidebarBridge.place`):
// personal order in the home session, else `move-workspace-to-group` on the
// owning daemon. While the sidebar document's first load is on the way
// (`SidebarDocWiring.awaitsDocument`) every placement waits: sent then, it
// would go to the older order, which the document ignores once it loads.
extension WindowManager {
    func applyPendingPlacements(live: Set<String>) {
        guard !pendingPlacements.isEmpty, !SidebarDocWiring.awaitsDocument else { return }
        NewWorkspacePlacements.apply(live: live, windows: self)
    }

    /// The placements held for the sidebar document's first show, once it shows (or its first load failed).
    func applyHeldPlacements() {
        applyPendingPlacements(live: Set(services.machines.daemons.flatMap { $0.store.workspaces.map(\.id) }))
    }

    /// Places a workspace this app just made (by a command whose reply
    /// names it) at `slot` of window `windowID` (nil: `workspaces.newPlacement`).
    /// `then` runs after the placement, with the window's sidebar.
    func place(newWorkspace id: String, in windowID: String, at slot: WorkspaceSlot?,
               then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)? = nil) {
        NewWorkspacePlacements.expect(id, in: windowID, slot: slot, byDefault: slot == nil ? NewWorkspacePlacements.rule(for: windowID, in: self) : nil,
                                      then: then, windows: self)
    }
}

extension NewWorkspacePlacements {
    /// Resolves the pending placements of `live` workspaces the daemon has, in the order they were asked for. Ones
    /// right after another for the same window, the same `bottom` or end-of-group slot and the same machine go with
    /// it as one move that keeps their order (workspaces held for the document's first show: one after another, each
    /// counted against a sidebar that does not show the one before it yet, would land out of order).
    static func apply(live: Set<String>, windows: WindowManager) {
        let services = windows.services
        let owner = { (id: String, pending: PendingPlacement) in pending.window ?? windows.registry.value.owner(of: id) }
        // A stand-in Cmd-N shows waits: a placement moves a workspace the daemon has.
        let ready = windows.pendingPlacements.filter { id, _ in live.contains(id) && services.machines.workspace(id: id)?.0.isProvisional != true }
            .sorted { $0.value.sequence < $1.value.sequence }
        var next = 0
        while next < ready.count {
            let (id, pending) = ready[next]
            var batch = [ready[next]]
            next += 1
            let machine = services.machines.daemon(forWorkspace: id)
            if pending.slot?.keepsOrderTogether == true {
                while next < ready.count, ready[next].value.slot == pending.slot, owner(ready[next].key, ready[next].value) == owner(id, pending),
                      services.machines.daemon(forWorkspace: ready[next].key) === machine {
                    batch.append(ready[next])
                    next += 1
                }
            }
            for (id, _) in batch { windows.pendingPlacements[id] = nil }
            guard let window = owner(id, pending), let bridge = windows.controller(for: window)?.sidebar, let daemon = machine else { continue }
            let sections = SidebarRowSection.withoutPlaceholders(bridge.model.sections)
            let section = SectionID.machine(MachineID(daemon.machineID))
            let homeID = home(services.machines)
            // This Mac's daemon placed the workspace by the setting in its create: no second write for that
            // slot. Another machine's create writes no row in this Mac's order, so the app places it.
            let slot = pending.slot ?? (daemon.isLocal ? pending.byDefault?.move(for: id, section: section, in: sections, home: homeID)
                : pending.byDefault?.slot(for: id, section: section, in: sections, home: homeID))
            let ids = batch.map(\.key)
            if let position = slot?.position(moving: Set(ids), section: section, in: sections) {
                bridge.place(ids.map(SidebarWorkspaceID.init), at: position, in: sections)
            }
            for (id, pending) in batch { ActionRunScope.carrying(pending.run) { pending.then?(id, bridge) } }
        }
    }
}

private extension WorkspaceSlot {
    /// Placing several workspaces here one after another keeps their order (each goes last), so one move of them
    /// all is the same; at `top` or `below` one after another reverses them, and those stay one move each.
    var keepsOrderTogether: Bool {
        switch self {
        case .bottom, .endOfGroup: true
        default: false
        }
    }
}
