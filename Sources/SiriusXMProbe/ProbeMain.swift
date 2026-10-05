import Foundation

/// Entry point for the Phase 0.5 auth-acquisition probe.
///
/// Two modes, chosen entirely by whether credentials are present in the
/// environment:
///   - unset: run only the credential-free shape checks, say plainly which
///     paths were skipped and why, exit cleanly;
///   - set: run the same checks plus the credential-gated paths.
///
/// Either way the output is the same machine-readable table.
@main
struct ProbeMain {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let outcome = CredentialPrompt.read(environment: environment)

        let credential: AccountCredential?
        switch outcome {
        case .available(let value):
            credential = value
            print("credential source: environment (\(CredentialPrompt.requiredVariableNames.joined(separator: ", ")))")
        case .missing(let names):
            credential = nil
            print("credential-gated paths: SKIPPED")
            print("  missing environment variable(s): \(names.joined(separator: ", "))")
            print("  export them in the shell to run the credentialed paths.")
            print("  do not pass credentials on the command line; argv is world-readable via ps.")
        }

        let client = EphemeralHTTPClient.shared
        let reports = await SessionShapeProbe.run(credential: credential, client: client)

        print("")
        print("path | result | statusCode | acquired | notes")
        print("--- | --- | --- | --- | ---")
        for report in reports {
            print(report.line)
        }
        print("")

        let acquired = reports.filter { $0.result.acquired }
        let observed = reports.filter {
            if case .observed = $0.result { return true }
            return false
        }

        print("summary: \(reports.count) paths, \(observed.count) observed anonymously, \(acquired.count) acquired a session")
        if credential == nil {
            print("credential-gated paths remain untested; see docs/protocol-auth-probe.md")
        }
    }
}