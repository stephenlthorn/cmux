#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import IOSurface
import QuartzCore
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// A geometry change that lands while a replacement replay token is in
/// flight is coalesced behind that token. When the token then failed its
/// fence for the stale geometry, nothing resubmitted it: the render gate
/// stayed held until the 2 s verified replay timeout rebuilt the surface.
@MainActor
@Suite("Verified replay geometry resubmit", .serialized)
struct VerifiedReplayGeometryResubmitTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceInput data: Data
        ) {}

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    /// The replay state right after the test's action, read in the same
    /// main-actor turn so a later callback cannot change it first.
    private struct ReplayState {
        let pendingID: UInt64?
        let retryCount: UInt8?
        let fenceRevision: UInt64?
        let geometryRevision: UInt64
        let submissionToken: UInt64?
    }

    @MainActor
    private final class StateBox {
        var finished = false
        var state: ReplayState?
    }

    private let delegate = Delegate()

    @Test("a replay callback rejected for a coalesced geometry change resubmits")
    func rejectedCallbackResubmits() async throws {
        let (view, window) = try mount()
        defer { tearDown(view, window) }
        let renderer = try #require(view.layer.sublayers?.first(where: view.isGhosttyRendererLayer))
        // A completed target on the layer, so the callback fails on geometry.
        renderer.contents = try makeIOSurface()

        let state = try await runReplacementReplay(on: view, acknowledged: false) { view in
            // A second geometry change, coalesced behind in-flight token 7.
            view.verifiedReplayGeometryRevision &+= 1
            let releasesGate = view.handleVerifiedReplayRenderPresented(token: 7)
            #expect(!releasesGate)
        }

        expectResubmitted(state)
    }

    @Test("an acknowledged replay whose geometry changed under a coalesced replacement resubmits")
    func acknowledgedReplayResubmits() async throws {
        let (view, window) = try mount()
        defer { tearDown(view, window) }

        let state = try await runReplacementReplay(on: view, acknowledged: true) { view in
            // The geometry changes after token 7 was acknowledged, before
            // its frame reached the presentation tree.
            view.verifiedReplayGeometryRevision &+= 1
            view.completePendingVerifiedReplayPresentationIfPresented()
        }

        expectResubmitted(state)
    }

    private func mount() throws -> (GhosttySurfaceView, UIWindow) {
        let view = GhosttySurfaceView(runtime: try GhosttyRuntime.shared(), delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        // The display link would poll the fence; these tests drive it.
        view.stopDisplayLink()
        return (view, window)
    }

    private func tearDown(_ view: GhosttySurfaceView, _ window: UIWindow) {
        view.verifiedReplayRenderSuppressed = false
        view.prepareForDismantle()
        view.removeFromSuperview()
        window.isHidden = true
    }

    /// Installs replay token 7 as the in-flight replacement holding the
    /// render gate, as `restartPendingVerifiedReplayPresentationForCurrentGeometry`
    /// leaves it, fenced at the current geometry; runs `act`; and returns the
    /// replay state it left. Everything runs in one main-actor turn.
    private func runReplacementReplay(
        on view: GhosttySurfaceView,
        acknowledged: Bool,
        act: @escaping @MainActor @Sendable (GhosttySurfaceView) -> Void
    ) async throws -> ReplayState {
        let surface = try #require(view.surface)
        let box = StateBox()
        let waiter = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<VerifiedReplayPresentedSubmission?, Never>) in
                let renderer = view.layer.sublayers?.first(where: view.isGhosttyRendererLayer)
                guard let geometry = verifiedReplayPresentationGeometry(
                    renderer: renderer,
                    host: view.layer,
                    viewportRect: view.terminalViewportRect
                ) else {
                    Issue.record("the surface has no renderer layer")
                    box.finished = true
                    continuation.resume(returning: nil)
                    return
                }
                var fence = VerifiedReplayPresentationFence(
                    expectedToken: 7,
                    expectedGeometryRevision: view.verifiedReplayGeometryRevision,
                    expectedGeometry: geometry
                )
                fence.markObservedFrameReady()
                if acknowledged {
                    let identity = VerifiedReplayRendererSurfaceIdentity(
                        id: 1,
                        seed: 1,
                        pixelWidth: Int((geometry.rendererBounds.width * geometry.rendererContentsScale).rounded()),
                        pixelHeight: Int((geometry.rendererBounds.height * geometry.rendererContentsScale).rounded())
                    )
                    let acknowledgedToken = fence.acknowledge(
                        token: 7,
                        modelIdentity: identity,
                        geometryRevision: view.verifiedReplayGeometryRevision,
                        geometry: geometry
                    )
                    #expect(acknowledgedToken)
                }
                view.verifiedReplayRenderSuppressed = true
                view.pendingVerifiedReplayPresentation = PendingVerifiedReplayPresentation(
                    id: 7,
                    startedAt: CACurrentMediaTime(),
                    surface: surface,
                    generation: view.surfaceGeneration,
                    read: nil,
                    fence: fence,
                    observedFrame: nil,
                    continuation: continuation
                )
                let started = view.enqueueRenderSubmission(GhosttySurfaceView.RenderSubmission(
                    token: 7,
                    generation: view.surfaceGeneration,
                    kind: .verifiedReplay,
                    surface: surface,
                    verifiedReplayRead: nil,
                    presentationRetryCount: 0
                ))
                #expect(started)
                view.renderReplacementInFlight = true

                act(view)

                let pending = view.pendingVerifiedReplayPresentation
                box.state = ReplayState(
                    pendingID: pending?.id,
                    retryCount: pending?.presentationRetryCount,
                    fenceRevision: pending?.fence.expectedGeometryRevision,
                    geometryRevision: view.verifiedReplayGeometryRevision,
                    submissionToken: view.renderSubmission?.token
                )
                box.finished = true
            }
        }
        while !box.finished {
            await Task.yield()
        }
        if let id = view.pendingVerifiedReplayPresentation?.id {
            view.completePendingVerifiedReplayPresentation(id: id, returning: nil)
        }
        _ = await waiter.value
        return try #require(box.state)
    }

    private func expectResubmitted(_ state: ReplayState) {
        #expect(state.pendingID != nil)
        #expect(state.pendingID != 7)
        #expect(state.retryCount == 1)
        #expect(state.fenceRevision == state.geometryRevision)
        #expect(state.submissionToken == state.pendingID)
    }

    private func makeIOSurface() throws -> IOSurface {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: 4,
            kIOSurfaceHeight: 4,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 16,
            kIOSurfacePixelFormat: UInt32(0x4247_5241),
        ]
        return try #require(IOSurfaceCreate(properties as CFDictionary))
    }
}
#endif
