internal import CMUXMobileCore

/// Captures the physical close started by a connect task's cancellation
/// handler. The abandoned-connect cleaner combines this task with any late
/// candidate close under one route lease.
actor MobileRPCConnectCancellationClose {
    private var closeTask: Task<Void, Never>?
    private var settledWithoutClose = false
    private var startWaiters: [
        CheckedContinuation<Task<Void, Never>?, Never>
    ] = []

    func start(_ candidate: any CmxByteTransport) {
        guard closeTask == nil, !settledWithoutClose else { return }
        let task = Task.detached {
            await candidate.close()
        }
        closeTask = task
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume(returning: task)
        }
    }

    func finishWithoutClose() {
        guard closeTask == nil, !settledWithoutClose else { return }
        settledWithoutClose = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    /// Settles the close once the connect task's `connect()` returned or
    /// threw. A cancel that lands after the cancellation handler's scope
    /// never runs `start`, so a cancelled task starts the close itself
    /// (a no-op when the handler already did) instead of waiting forever for
    /// a start that never comes.
    func settleAfterConnect(
        _ candidate: any CmxByteTransport,
        cancelled: Bool
    ) {
        if cancelled {
            start(candidate)
        } else {
            finishWithoutClose()
        }
    }

    func task() async -> Task<Void, Never>? {
        if let closeTask {
            return closeTask
        }
        if settledWithoutClose {
            return nil
        }
        return await withCheckedContinuation {
            startWaiters.append($0)
        }
    }
}
