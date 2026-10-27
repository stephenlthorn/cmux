public import Foundation

/// The Mac identity a phone addresses an encrypted inline-notification reply
/// to: the Mac half of the ``PhonePushDeviceTuple`` the push key exchange hands
/// the phone. The presence worker's `GET /v1/replies/e2e` requires every field
/// (`parsePhoneReplyTarget` in workers/presence/src/replies.ts) and answers
/// 400 without them, so the Mac fetches its inbox with this same tuple.
public struct PhoneReplyFetchTarget: Equatable, Sendable {
    public let macDeviceID: String
    public let macInstanceTag: String
    public let macBuildID: String

    public init(macDeviceID: String, macInstanceTag: String, macBuildID: String) {
        self.macDeviceID = macDeviceID
        self.macInstanceTag = macInstanceTag
        self.macBuildID = macBuildID
    }

    /// The build ID the key exchange pins for this Mac: its bundle identifier.
    public static func macBuildID(bundleIdentifier: String?) -> String {
        bundleIdentifier ?? "cmux"
    }

    /// Query items for the inbox fetch, spelled as the worker reads them.
    public var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "macDeviceId", value: macDeviceID),
            URLQueryItem(name: "macInstanceTag", value: macInstanceTag),
            URLQueryItem(name: "macBuildID", value: macBuildID),
        ]
    }
}
