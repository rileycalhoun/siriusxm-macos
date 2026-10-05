import Foundation
import Testing

@testable import SiriusXMProbe

/// Mapping of `messages[].code`.
///
/// `100` success, `201`/`208` session gone, anything else an error the probe
/// must report rather than guess at. `101` was observed live against the
/// module API and is not part of the published set, so it gets its own case
/// rather than falling into `unrecognized`.
@Suite("Module message code mapping")
struct MessageCodeTests {
    @Test("100 is success")
    func hundredIsSuccess() {
        let code = ModuleMessageCode.classify(100)

        #expect(code == .success)
        #expect(code.isSuccess)
        #expect(!code.isSessionExpired)
        #expect(!code.isCredentialFailure)
        #expect(code.rawCode == 100)
    }

    @Test("101 is a credential failure")
    func oneOhOneIsCredentialFailure() {
        let code = ModuleMessageCode.classify(101)

        #expect(code == .badCredentials)
        #expect(code.isCredentialFailure)
        #expect(!code.isSessionExpired)
        #expect(!code.isSuccess)
    }

    @Test("201 and 208 both mean the session is gone")
    func twoOhOneAndTwoOhEightAreExpired() {
        for raw in [201, 208] {
            let code = ModuleMessageCode.classify(raw)

            #expect(code.isSessionExpired, "\(raw) must be treated as expired")
            #expect(!code.isSuccess, "\(raw) must not be treated as success")
            #expect(!code.isCredentialFailure, "\(raw) must not be treated as bad credentials")
            #expect(code.rawCode == raw)
        }
    }

    @Test("an unmapped code is carried verbatim, never rounded to success or expiry")
    func unmappedCodeIsCarried() {
        let code = ModuleMessageCode.classify(999)

        #expect(code == .unrecognized(999))
        #expect(code.rawCode == 999)
        #expect(!code.isSuccess)
        #expect(!code.isSessionExpired)
        #expect(!code.isCredentialFailure)
        #expect(code.description == "999")
    }

    @Test("the three failure classes are mutually exclusive")
    func failureClassesAreMutuallyExclusive() {
        let codes = (0...300).map(ModuleMessageCode.classify)

        for code in codes {
            let flags = [code.isSuccess, code.isCredentialFailure, code.isSessionExpired]
            #expect(flags.filter { $0 }.count <= 1, "\(code) matched more than one class")
        }
    }

    @Test("fixtures carry their expected classifications")
    func fixturesCarryExpectedClassifications() throws {
        let expected: [String: ModuleMessageCode] = [
            "module-auth-unauthenticated.json": .badCredentials,
            "module-resume-unauthenticated.json": .authenticationRequired,
            "module-auth-code-208.json": .sessionExpired,
            "module-auth-code-999.json": .unrecognized(999),
            "module-auth-success.json": .success
        ]

        for (name, code) in expected {
            let parsed = try ModuleAPIParser.parse(Fixtures.text(name))
            #expect(parsed.primaryCode == code, "\(name) classified wrong")
        }
    }

    @Test("message text is read but never used as a control signal")
    func messageTextIsCarriedNotInterpreted() throws {
        let parsed = try ModuleAPIParser.parse(Fixtures.text("module-auth-unauthenticated.json"))

        #expect(parsed.messages.count == 1)
        #expect(parsed.messages[0].text == "Bad username/password")
        #expect(parsed.messages[0].classification == .badCredentials)
    }

    @Test("a response with no messages array yields no messages")
    func absentMessagesYieldEmpty() throws {
        let parsed = try ModuleAPIParser.parse(#"{"ModuleListResponse":{"status":1}}"#)

        #expect(parsed.messages.isEmpty)
        #expect(parsed.primaryCode == nil)
        #expect(parsed.status.isAuthenticated)
    }

    @Test("a missing status field is never read as authenticated")
    func missingStatusIsNotAuthenticated() throws {
        let parsed = try ModuleAPIParser.parse(#"{"ModuleListResponse":{"messages":[]}}"#)

        #expect(!parsed.status.isAuthenticated)
        #expect(parsed.status == .unrecognized(-1))
    }
}