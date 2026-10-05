import Foundation

/// A username and password held only for the lifetime of one process.
///
/// The values are private and reachable only through `withStandardAuth`, so
/// they cannot be interpolated into a log line or a report row by accident.
/// Same redaction contract as `SessionMaterial`.
struct AccountCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Hands the pair to a builder that immediately folds it into a request
    /// body. The closure is non-escaping: the values cannot outlive the call.
    func withStandardAuth(_ body: (String, String) -> Void) {
        body(username, password)
    }

    var description: String {
        "AccountCredential(username: <redacted>, password: <redacted>)"
    }

    var debugDescription: String { description }
}

/// Reads account credentials from the process environment and nowhere else.
///
/// Deliberately not supported:
///   - command-line arguments, because `ps` publishes the whole argv of every
///     process on the machine to every other process on the machine;
///   - files, `UserDefaults`, plists, or the keychain, because Phase 0.5 is
///     not allowed to persist credentials anywhere;
///   - interactive prompting, because the probe has to run unattended.
enum CredentialPrompt {
    static let usernameVariable = "SXM_USERNAME"
    static let passwordVariable = "SXM_PASSWORD"

    enum Outcome: Sendable {
        case available(AccountCredential)
        /// Names of the variables that were absent or empty. Names only.
        case missing([String])
    }

    static var requiredVariableNames: [String] { [usernameVariable, passwordVariable] }

    /// Pure function over the environment dictionary so it is testable
    /// without mutating the real process environment.
    static func read(environment: [String: String]) -> Outcome {
        // The username is trimmed because a stray newline from a shell
        // `export` would otherwise become part of the login. The password is
        // never trimmed: leading and trailing spaces can be significant.
        let username = (environment[usernameVariable] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = environment[passwordVariable] ?? ""

        var missing: [String] = []
        if username.isEmpty { missing.append(usernameVariable) }
        if password.isEmpty { missing.append(passwordVariable) }

        guard missing.isEmpty else { return .missing(missing) }
        return .available(AccountCredential(username: username, password: password))
    }
}