import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Mobile task model shell runner")
struct MobileTaskModelShellRunnerTests {
    private let runner = MobileTaskModelShellRunner(shellPath: "/bin/sh")

    @Test func fastCommandReturnsStandardOutput() async {
        let output = await runner.run(command: "echo cmux-runner-ok", timeout: .seconds(10))

        // Login-profile output may precede the command's own line.
        #expect(output?.hasSuffix("cmux-runner-ok\n") == true)
    }

    @Test func backgroundDescendantHoldingStdoutDoesNotDelayDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now

        let output = await runner.run(command: "(sleep 5) & echo hi", timeout: .seconds(1))

        let elapsed = start.duration(to: clock.now)
        #expect(output == nil)
        #expect(elapsed < .milliseconds(2500), "returned after \(elapsed)")
    }

    @Test func foregroundChildHoldingStdoutDoesNotDelayDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now

        let output = await runner.run(command: "sleep 7; echo late", timeout: .seconds(1))

        let elapsed = start.duration(to: clock.now)
        #expect(output == nil)
        #expect(elapsed < .milliseconds(2500), "returned after \(elapsed)")
    }
}
