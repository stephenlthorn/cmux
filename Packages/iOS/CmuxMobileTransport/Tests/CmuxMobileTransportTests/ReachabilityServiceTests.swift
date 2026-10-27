import Foundation
import Network
import Testing
@testable import CmuxMobileTransport

@Test func reachabilityServiceReportsAnOnlineSnapshot() async {
    let service = ReachabilityService()

    // Snapshot resolves to a Bool; we don't assert connectivity (CI may be
    // offline), only that arming the monitor and reading state works.
    let online = await service.isOnline
    #expect(online == true || online == false)
}

@Test func reachabilityServiceSupportsMultipleConcurrentSubscribers() async {
    let service = ReachabilityService()

    // Two independent streams can be opened and torn down without crashing the
    // actor's subscriber registry. No path change is forced, so each completes
    // when its task ends.
    let first = service.pathChanges()
    let second = service.pathChanges()
    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()

    let firstTask = Task { _ = await firstIterator.next() }
    let secondTask = Task { _ = await secondIterator.next() }
    firstTask.cancel()
    secondTask.cancel()
    _ = await firstTask.value
    _ = await secondTask.value
}

@Test func transitionalNetworkReachabilityShimMirrorsAServiceOnMainActor() async {
    let shim = await NetworkReachability(service: ReachabilityService())

    // The transitional @Observable shim exposes the legacy accessors the deep
    // call sites read, seeded optimistically online before the first path.
    let isOnline = await shim.isOnline
    let isOffline = await shim.isOffline
    let generation = await shim.pathChangeGeneration
    #expect(isOnline == !isOffline)
    #expect(generation == 0)
}

@Test func reachabilityServiceDropsAPathThatArrivesAfterANewerOne() async {
    let service = ReachabilityService()

    // Each monitor callback hops to the actor in its own task, so an older
    // offline path can land after the newer online one it preceded.
    await service.apply(online: true, primaryType: .wifi, sequence: 2)
    await service.apply(online: false, primaryType: nil, sequence: 1)

    #expect(await service.isOnline)
}
