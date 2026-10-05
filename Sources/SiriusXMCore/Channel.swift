import Foundation

/// How the guide groups channels.
///
/// The taxonomy is provisional. It is a presentation grouping, not a claim
/// about SiriusXM's own channel metadata, and it is expected to change when a
/// later phase can read the real category out of a guide response.
public enum ChannelCategory: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case music
    case news
    case sports
    case talk
    case weather

    public var description: String { rawValue }
}

/// One playable channel.
///
/// A pure value type: no image is loaded, no URL is fetched, nothing here
/// knows where any of these fields came from. Artwork is a `RedactingURL`
/// rather than a `URL` because an image URL is the kind of field that
/// eventually picks up a query string, and this app does not need a URL that
/// can leak to be laid out.
public struct Channel: Sendable, Hashable, Identifiable, CustomStringConvertible {
    /// Stable identifier from the catalog, not the display number. Numbers are
    /// reused and re-ordered between regions and over time.
    public let id: String

    public let name: String

    /// Display number where the catalog supplies one.
    public let number: Int?

    public let category: ChannelCategory

    /// One line of catalog copy. Never shown as a headline.
    public let shortDescription: String?

    public let artwork: RedactingURL?

    public init(
        id: String,
        name: String,
        number: Int? = nil,
        category: ChannelCategory,
        shortDescription: String? = nil,
        artwork: RedactingURL? = nil
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.category = category
        self.shortDescription = shortDescription
        self.artwork = artwork
    }

    public var description: String {
        "Channel(\(id), \(name))"
    }
}
