import Foundation
import Testing

@testable import SiriusXMProtocol

/// The endpoint layer is the only place that assembles a SiriusXM address,
/// so these tests are about two things: that the addresses are the ones the
/// Phase 0.5 probe observed, and that assembling one never yields something
/// whose query string can be printed.
@Suite("Endpoints")
struct EndpointTests {
    @Test("an endpoint builds an https address from its host and path")
    func endpointBuildsAnAddress() throws {
        let url = try #require(SiriusXMEndpoints.profileMe.redactedURL())

        #expect(url.scheme == "https")
        #expect(url.host == "api.edge-gateway.siriusxm.com")
        #expect(url.path == "/profile/v4/profiles/me")
        #expect(!url.carriesSensitiveComponents)
    }

    @Test("the three hosts are the three that Phase 0.5 observed")
    func hostsAreStable() {
        #expect(SiriusXMHost.edgeGateway.name == "api.edge-gateway.siriusxm.com")
        #expect(SiriusXMHost.player.name == "player.siriusxm.com")
        #expect(SiriusXMHost.webPlayer.name == "www.siriusxm.com")
    }

    @Test("the web player entry point is the only confirmed human route")
    func browserEntryIsOnTheWebPlayer() throws {
        let url = try #require(SiriusXMEndpoints.browserEntry.redactedURL())

        #expect(url.host == "www.siriusxm.com")
        #expect(url.path == "/player")
    }

    @Test("the module API lives on the player host under the versioned prefix")
    func modulePathsAreVersioned() throws {
        let url = try #require(SiriusXMEndpoints.module(.resume, trial: true).redactedURL())

        #expect(url.host == "player.siriusxm.com")
        #expect(url.path == "/rest/v2/experience/modules/resume")
    }

    @Test("an endpoint with a query never renders it")
    func queryIsNeverRendered() throws {
        let endpoint = SiriusXMEndpoints.module(.resume, trial: true)
        let url = try #require(endpoint.redactedURL())

        // The query is real, and it is still redacted on the way out.
        #expect(endpoint.query == "OAtrial=false")
        #expect(url.carriesSensitiveComponents)
        #expect(url.description.contains("/rest/v2/experience/modules/resume"))
        #expect(!url.description.contains("OAtrial"))
        #expect(!url.debugDescription.contains("OAtrial"))
    }

    @Test("an endpoint with no query renders in full")
    func tokenFreeEndpointsRenderInFull() throws {
        let url = try #require(SiriusXMEndpoints.sessionRefresh.redactedURL())

        #expect(url.description == "https://api.edge-gateway.siriusxm.com/session/v1/sessions/refresh")
    }

    @Test("displayTarget is host plus path and never carries a query")
    func displayTargetExcludesTheQuery() {
        #expect(SiriusXMEndpoints.module(.resume, trial: true).displayTarget
            == "player.siriusxm.com/rest/v2/experience/modules/resume")
    }

    @Test("a host's base is an https redacting value, not a URL")
    func hostBaseIsRedacting() throws {
        let base = try #require(SiriusXMHost.player.base)

        #expect(base.description == "https://player.siriusxm.com")
        #expect(base.carriesSensitiveComponents == false)
    }

    @Test("the legacy authentication operation is named but not reachable")
    func authenticationOperationIsNamed() {
        // Phase 0.5 found no evidence this operation still grants a session.
        // The name is kept so a future phase can prove or delete it, and
        // `SiriusXMEndpoints.module` is the only way to build a request for it,
        // so nothing calls it by accident.
        #expect(SiriusXMModuleOperation.authentication.name == "modify/authentication")
        #expect(SiriusXMModuleOperation.resume.name == "resume")
    }

    @Test("interpolating an endpoint into a log line yields no query")
    func interpolationIsSafe() throws {
        let endpoint = SiriusXMEndpoints.module(.authentication, trial: true)
        let line = "calling \(endpoint.displayTarget)"

        #expect(line == "calling player.siriusxm.com/rest/v2/experience/modules/modify/authentication")
        #expect(!line.contains("OAtrial"))
    }
}
