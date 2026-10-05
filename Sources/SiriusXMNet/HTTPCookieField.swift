import Foundation

/// One `Set-Cookie` field: a name and its value.
///
/// The value is stored because a caller needs it to authenticate, and is never
/// rendered. Both `description` and `debugDescription` print the name and
/// nothing else, so a cookie field can be interpolated, nested in a struct, or
/// put in an array and still not leak.
///
/// This is HTTP grammar, so it lives in the transport. Which cookie names are
/// meaningful is protocol knowledge and stays in `SiriusXMProtocol`.
public struct HTTPCookieField: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var description: String { "\(name)=<redacted>" }
    public var debugDescription: String { "\(name)=<redacted>" }
}

extension SetCookieHeaderParser {
    /// Parses a folded `Set-Cookie` header into cookie fields.
    ///
    /// The convenience form of `fields(fromHeader:)` for callers that want a
    /// name and a value rather than an `HTTPHeader`. Sensitivity is implied by
    /// the type, so a cookie field cannot be marked structural by accident.
    public static func cookieFields(fromHeader header: String) -> [HTTPCookieField] {
        fields(fromHeader: header).map { field in
            HTTPCookieField(name: field.name, value: field.resolvedValue)
        }
    }
}
