import Testing

@testable import CmuxRemoteSession

@Suite struct RemoteTmuxPhoneWindowClaimTests {
    @Test func aPhoneViewingASinglePaneWindowSizesItToThePhone() {
        let claim = RemoteTmuxPhoneWindowClaim.size(phone: (72, 40), mac: (128, 35), beforePhone: nil, paneCount: 1)
        #expect(claim?.columns == 72)
        #expect(claim?.rows == 35)
    }

    @Test func thePhoneLeavingGivesTheWindowBackToTheMac() {
        let claim = RemoteTmuxPhoneWindowClaim.size(phone: nil, mac: (128, 35), beforePhone: (152, 45), paneCount: 1)
        #expect(claim?.columns == 128)
        #expect(claim?.rows == 35)
    }

    @Test func aPhoneAloneSizesTheWindowWhenTheMacHasNotMeasuredIt() {
        let claim = RemoteTmuxPhoneWindowClaim.size(phone: (72, 40), mac: nil, beforePhone: nil, paneCount: 1)
        #expect(claim?.columns == 72)
        #expect(claim?.rows == 40)
    }

    @Test func splitWindowsAreLeftToTheMac() {
        #expect(RemoteTmuxPhoneWindowClaim.size(phone: (72, 40), mac: (128, 35), beforePhone: nil, paneCount: 2) == nil)
    }

    @Test func nothingToClaimWithoutAnySize() {
        #expect(RemoteTmuxPhoneWindowClaim.size(phone: nil, mac: nil, beforePhone: nil, paneCount: 1) == nil)
    }

    @Test func thePhoneLeavingAWindowTheMacNeverMeasuredRestoresItsEarlierSize() {
        let claim = RemoteTmuxPhoneWindowClaim.size(phone: nil, mac: nil, beforePhone: (152, 45), paneCount: 1)
        #expect(claim?.columns == 152)
        #expect(claim?.rows == 45)
    }
}
