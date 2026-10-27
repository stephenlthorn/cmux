import Foundation
import Testing
@testable import CmuxPhonePush

@Suite struct PhoneReplyFetchTargetTests {
    /// The presence worker's GET /v1/replies/e2e reads exactly these query
    /// parameters (`parsePhoneReplyTarget` in workers/presence/src/replies.ts)
    /// and answers 400 invalid_mac_device_id when any required one is missing.
    @Test func fetchQueryNamesEveryFieldTheWorkerRequires() {
        let target = PhoneReplyFetchTarget(
            macDeviceID: "device",
            macInstanceTag: "stephen",
            macBuildID: "com.cmuxterm.app.debug.stephen"
        )

        let query = Dictionary(
            uniqueKeysWithValues: target.queryItems.map { ($0.name, $0.value) }
        )

        #expect(query == [
            "macDeviceId": "device",
            "macInstanceTag": "stephen",
            "macBuildID": "com.cmuxterm.app.debug.stephen",
        ])
    }

    /// The key exchange pins the bundle identifier as the build ID, so the
    /// fetch must derive it the same way, including the fallback.
    @Test func macBuildIDIsTheBundleIdentifier() {
        #expect(PhoneReplyFetchTarget.macBuildID(bundleIdentifier: "com.cmuxterm.app") == "com.cmuxterm.app")
        #expect(PhoneReplyFetchTarget.macBuildID(bundleIdentifier: nil) == "cmux")
    }
}
