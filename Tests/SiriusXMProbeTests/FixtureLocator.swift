import Foundation
import Testing

@testable import SiriusXMProbe

/// Locates the checked-in synthetic fixtures.
///
/// Fixtures are the only data this suite reads. Nothing here opens a socket,
/// resolves a host, or touches the keychain, which is what makes
/// `swift test` runnable fully offline.
enum Fixtures {
    static let directoryName = "Fixtures"

    static func directoryURL() throws -> URL {
        let root = try #require(
            Bundle.module.resourceURL,
            "the test bundle has no resource directory"
        )
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try #require(
            FileManager.default.fileExists(atPath: directory.path),
            "the fixtures directory is missing from the test bundle"
        )
        return directory
    }

    static func fileURL(_ name: String) throws -> URL {
        let url = try directoryURL().appendingPathComponent(name, isDirectory: false)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "fixture \(name) is missing"
        )
        return url
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: try fileURL(name)), as: UTF8.self)
    }

    /// Single-line fixtures are read without their trailing newline so a
    /// `Set-Cookie` header string can be compared directly.
    static func singleLine(_ name: String) throws -> String {
        try text(name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func allFileURLs() throws -> [URL] {
        let directory = try directoryURL()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.sorted().map { directory.appendingPathComponent($0) }
    }

    /// Parses a `Set-Cookie`-shaped fixture into cookie fields with no network.
    static func cookieFields(_ name: String) throws -> [HTTPCookieField] {
        EphemeralHTTPClient.cookieFields(fromHeader: try singleLine(name))
    }
}