import Foundation

/// When a channel is playing something.
///
/// Live channels have no schedule, so "always live" is a first-class case
/// rather than an open-ended window. Without it, a live channel would have to
/// be modelled as a programme that never ends, which every consumer would then
/// have to special-case.
public enum GuideAvailability: Sendable, Hashable {
    /// A programme with a window.
    case scheduled(startsAt: Date, endsAt: Date)
    /// The channel plays continuously and has no programme list.
    case alwaysLive
    /// The guide has not been consulted, or the channel is not in it.
    case unknown

    public var isLive: Bool {
        switch self {
        case .alwaysLive: return true
        case .scheduled(let startsAt, let endsAt): return startsAt == endsAt
        case .unknown: return false
        }
    }
}

/// One programme on the guide.
///
/// Timeshift is entirely client-side on this service, so `startsAt` and
/// `endsAt` are the only record of what a show was. Nothing here fetches
/// anything or caches anything.
public struct GuideEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let channelID: String
    public let title: String
    public let artist: String?

    public let availability: GuideAvailability

    public init(
        id: String,
        channelID: String,
        title: String,
        artist: String? = nil,
        availability: GuideAvailability
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.artist = artist
        self.availability = availability
    }

    /// True when this entry has no schedule to seek within.
    public var isLive: Bool { availability.isLive }

    /// The scheduled window, or `nil` for live and unknown channels.
    public var window: (start: Date, end: Date)? {
        if case .scheduled(let startsAt, let endsAt) = availability {
            return (startsAt, endsAt)
        }
        return nil
    }
}
