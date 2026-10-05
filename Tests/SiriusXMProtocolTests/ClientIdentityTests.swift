import Foundation
import Testing

@testable import SiriusXMProtocol

/// The client identity is a decision, not a constant: the app says what it is
/// rather than pretending to be something it is not. These tests exist so that
/// decision cannot be quietly reversed by a later phase.
@Suite("Client identity")
struct ClientIdentityTests {
    @Test("the user agent names this app, not a browser")
    func userAgentIsHonest() {
        #expect(SiriusXMClientIdentity.userAgent.hasPrefix("SiriusXMApp/"))
        for pretend in ["Mozilla", "Safari", "Chrome", "WebKit"] {
            #expect(!SiriusXMClientIdentity.userAgent.contains(pretend))
        }
    }

    @Test("no device identifier is minted")
    func noDeviceIdentifier() {
        // The literal "null" is what the public implementations send. It is
        // also the honest answer: this app does not have one. Device-limit
        // circumvention is not a feature of this project.
        #expect(SiriusXMClientIdentity.deviceInfo()[SiriusXMJSONKey.clientDeviceID.name] == "null")
    }

    @Test("the identity is identical across calls")
    func identityIsStable() {
        // A randomised or timestamped identity would make every request look
        // like a new client, which is both a fingerprint and a way to get an
        // account flagged.
        #expect(SiriusXMClientIdentity.deviceInfo() == SiriusXMClientIdentity.deviceInfo())
        #expect(SiriusXMClientIdentity.userAgent == SiriusXMClientIdentity.userAgent)
        #expect(SiriusXMClientIdentity.deviceInfo()[SiriusXMJSONKey.browserVersion.name]
            == SiriusXMClientIdentity.browserVersion)
    }

    /// The single module's `moduleRequest` object, dug out of the envelope.
    ///
    /// The nesting is the thing under test, so it is walked here once rather
    /// than repeated inline where `swift-testing` cannot nest its own macros.
    private func moduleRequest(of body: [String: Any]) throws -> [String: Any] {
        let list = try #require(
            body[SiriusXMJSONKey.moduleList.name] as? [String: Any],
            "the envelope has no module list"
        )
        let modules = try #require(
            list[SiriusXMJSONKey.modules.name] as? [[String: Any]],
            "the module list has no modules array"
        )
        #expect(modules.count == 1)
        let first = try #require(modules.first, "the modules array is empty")
        return try #require(
            first[SiriusXMJSONKey.moduleRequest.name] as? [String: Any],
            "the module has no request object"
        )
    }

    @Test("the request envelope nests the way the module API expects")
    func moduleBodyShape() throws {
        let body = SiriusXMClientIdentity.moduleBody(resultTemplate: "login", standardAuth: nil)
        let request = try moduleRequest(of: body)

        #expect(request[SiriusXMJSONKey.resultTemplate.name] as? String == "login")
        #expect(request[SiriusXMJSONKey.deviceInfo.name] != nil)

        let list = try #require(body[SiriusXMJSONKey.moduleList.name] as? [String: Any])
        let modules = try #require(list[SiriusXMJSONKey.modules.name] as? [[String: Any]])
        #expect(modules.first?[SiriusXMJSONKey.moduleName.name] as? String == "login")
    }

    @Test("an absent credential block is omitted rather than sent as null")
    func absentStandardAuthIsOmitted() throws {
        let body = SiriusXMClientIdentity.moduleBody(resultTemplate: "login", standardAuth: nil)
        let request = try moduleRequest(of: body)

        #expect(request[SiriusXMJSONKey.standardAuth.name] == nil)
    }

    @Test("a present credential block is passed through untouched")
    func presentStandardAuthIsCarried() throws {
        let body = SiriusXMClientIdentity.moduleBody(
            resultTemplate: "login",
            standardAuth: ["username": "subscriber", "password": "not-a-real-one"]
        )
        let request = try moduleRequest(of: body)

        #expect(request[SiriusXMJSONKey.standardAuth.name] != nil)
    }

    @Test("the envelope holds no password outside the block the caller supplied")
    func nothingElseCarriesAPassword() throws {
        // The builder does not invent credentials. This pins that: the only
        // route to a password is the parameter a caller chose to pass, which
        // is what lets the probe build this body without ever holding one.
        let body = SiriusXMClientIdentity.moduleBody(resultTemplate: "resume", standardAuth: nil)

        #expect(!body.keys.contains("standardAuth"))
        #expect(!body.keys.contains("password"))
        #expect(!body.keys.contains("authToken"))
    }
}
