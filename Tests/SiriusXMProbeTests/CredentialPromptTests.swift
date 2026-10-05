import Foundation
import Testing

@testable import SiriusXMProbe

/// The credential source is the process environment and nothing else.
///
/// `read(environment:)` is a pure function over a dictionary so this suite
/// never mutates, and never needs, a real environment.
@Suite("Credential prompt")
struct CredentialPromptTests {
    @Test("both variables present yields a credential")
    func bothPresentYieldsCredential() throws {
        let outcome = CredentialPrompt.read(environment: [
            CredentialPrompt.usernameVariable: "operator",
            CredentialPrompt.passwordVariable: "synthetic"
        ])

        guard case .available(let credential) = outcome else {
            Issue.record("expected an available credential")
            return
        }

        var seen: [String] = []
        credential.withStandardAuth { username, password in
            seen = [username, password]
        }
        #expect(seen == ["operator", "synthetic"])
    }

    @Test("an absent password is reported by name only")
    func absentPasswordIsReportedByName() throws {
        let outcome = CredentialPrompt.read(environment: [
            CredentialPrompt.usernameVariable: "operator"
        ])

        guard case .missing(let names) = outcome else {
            Issue.record("expected a missing outcome")
            return
        }
        #expect(names == [CredentialPrompt.passwordVariable])
    }

    @Test("an absent username is reported by name only")
    func absentUsernameIsReportedByName() throws {
        let outcome = CredentialPrompt.read(environment: [
            CredentialPrompt.passwordVariable: "synthetic"
        ])

        guard case .missing(let names) = outcome else {
            Issue.record("expected a missing outcome")
            return
        }
        #expect(names == [CredentialPrompt.usernameVariable])
    }

    @Test("an empty environment is refused, not defaulted")
    func emptyEnvironmentIsRefused() throws {
        guard case .missing(let names) = CredentialPrompt.read(environment: [:]) else {
            Issue.record("expected a missing outcome")
            return
        }
        #expect(names == CredentialPrompt.requiredVariableNames)
    }

    @Test("an empty password is refused")
    func emptyPasswordIsRefused() throws {
        let outcome = CredentialPrompt.read(environment: [
            CredentialPrompt.usernameVariable: "operator",
            CredentialPrompt.passwordVariable: ""
        ])

        guard case .missing(let names) = outcome else {
            Issue.record("expected a missing outcome")
            return
        }
        #expect(names == [CredentialPrompt.passwordVariable])
    }

    @Test("a whitespace-only username is refused")
    func whitespaceUsernameIsRefused() throws {
        let outcome = CredentialPrompt.read(environment: [
            CredentialPrompt.usernameVariable: "   ",
            CredentialPrompt.passwordVariable: "synthetic"
        ])

        guard case .missing(let names) = outcome else {
            Issue.record("expected a missing outcome")
            return
        }
        #expect(names == [CredentialPrompt.usernameVariable])
    }

    @Test("a stray newline around the username is trimmed, the password is left alone")
    func usernameIsTrimmedAndPasswordIsNot() throws {
        let outcome = CredentialPrompt.read(environment: [
            CredentialPrompt.usernameVariable: " operator\n",
            CredentialPrompt.passwordVariable: " spaced "
        ])

        guard case .available(let credential) = outcome else {
            Issue.record("expected an available credential")
            return
        }

        var seen: [String] = []
        credential.withStandardAuth { username, password in
            seen = [username, password]
        }
        #expect(seen == ["operator", " spaced "])
    }

    @Test("only two variable names exist, and neither is a command-line flag")
    func variableSurfaceIsExactlyTwoNames() {
        #expect(CredentialPrompt.requiredVariableNames == ["SXM_USERNAME", "SXM_PASSWORD"])
    }
}