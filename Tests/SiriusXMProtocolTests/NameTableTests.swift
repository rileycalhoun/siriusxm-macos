import Foundation
import Testing

@testable import SiriusXMProtocol

/// The name tables are the module's reason to exist, so the tests check the
/// two properties that make it one: the wire names are right, and they are
/// declared once.
@Suite("SiriusXM name tables")
struct NameTableTests {
    @Test("the module API envelope keys are the observed ones")
    func moduleEnvelopeKeys() {
        #expect(SiriusXMJSONKey.moduleListResponse.name == "ModuleListResponse")
        #expect(SiriusXMJSONKey.status.name == "status")
        #expect(SiriusXMJSONKey.messages.name == "messages")
        #expect(SiriusXMJSONKey.code.name == "code")
        #expect(SiriusXMJSONKey.message.name == "message")
    }

    @Test("the account identifier is spelled gupId on the wire")
    func accountIdentifierKey() {
        // Not `gupID`, not `gup_id`. The casing is SiriusXM's and the parser
        // has to match it exactly.
        #expect(SiriusXMJSONKey.gupID.name == "gupId")
    }

    @Test("the token headers use their canonical capitalisation")
    func headerNames() {
        #expect(SiriusXMHeaderName.authorization.name == "Authorization")
        #expect(SiriusXMHeaderName.cookie.name == "Cookie")
        #expect(SiriusXMHeaderName.setCookie.name == "Set-Cookie")
        #expect(SiriusXMHeaderName.userAgent.name == "User-Agent")
        #expect(SiriusXMHeaderName.cacheControl.name == "Cache-Control")
        #expect(SiriusXMHeaderName.contentType.name == "Content-Type")
        #expect(SiriusXMHeaderName.clock.name == "x-sxm-clock")
    }

    @Test("the cookie names are the observed ones")
    func cookieNames() {
        #expect(SiriusXMCookieName.auth.name == "SXMAUTH")
        #expect(SiriusXMCookieName.akToken.name == "SXMAKTOKEN")
        #expect(SiriusXMCookieName.data.name == "SXMDATA")
        #expect(SiriusXMCookieName.sessionID.name == "JSESSIONID")
    }

    @Test("three of the four cookies can act as the subscriber")
    func sessionBearingCookies() {
        // `SXMAUTH` and `SXMAKTOKEN` are enough to authenticate as the
        // subscriber. `SXMDATA` identifies the account, so it counts. The JS
        // session id does not survive a rebuild of the session.
        #expect(SiriusXMCookieName.sessionBearing == [.auth, .akToken, .data])
        #expect(SiriusXMCookieName.sessionBearing.contains(SiriusXMCookieName.sessionID) == false)
    }

    @Test("no two names in a table collide")
    func noCollisions() {
        let keys = [
            SiriusXMJSONKey.moduleListResponse, .status, .messages, .code, .message,
            .gupID, .moduleList, .modules, .moduleName, .moduleRequest, .resultTemplate,
            .standardAuth, .deviceInfo, .appRegion, .browser, .browserVersion,
            .clientDeviceID, .clientDeviceType, .deviceModel, .osVersion, .platform,
            .player, .sxmAppVersion
        ]
        #expect(Set(keys.map(\.name)).count == keys.count)

        let headers = [
            SiriusXMHeaderName.authorization, .cookie, .setCookie, .userAgent, .accept,
            .cacheControl, .contentType, .origin, .referer, .clock
        ]
        #expect(Set(headers.map(\.name)).count == headers.count)
    }

    @Test("the JSON key table covers every key the request builder emits")
    func requestBuilderUsesOnlyDeclaredKeys() throws {
        // The point of the table is that a hand-typed key is a compile-free
        // way to drift. Assert the deviceInfo object is built entirely from
        // declared keys and has the shape the module API expects.
        let info = SiriusXMClientIdentity.deviceInfo()

        #expect(info.count == 10)
        #expect(info[SiriusXMJSONKey.appRegion.name] == "US")
        #expect(info[SiriusXMJSONKey.clientDeviceID.name] == "null")
        #expect(info[SiriusXMJSONKey.platform.name] == "Web")
        #expect(info[SiriusXMJSONKey.player.name] == "html5")
    }
}

/// The message code table. Every value here is unverified against SiriusXM
/// and carried from observation, so the tests are about the *behaviour* of the
/// mapping rather than the correctness of the numbers.
@Suite("Module message codes")
struct ModuleMessageCodeTests {
    @Test("100 is success")
    func successIsOneHundred() {
        #expect(ModuleMessageCode.classify(100) == .success)
        #expect(ModuleMessageCode.success.isSuccess)
    }

    @Test("101 is a credential failure, not an expiry")
    func badCredentialsIsSeparate() {
        let code = ModuleMessageCode.classify(101)

        #expect(code == .badCredentials)
        #expect(code.isCredentialFailure)
        #expect(code.isSessionExpired == false)
    }

    @Test("201 and 208 both mean the session is gone")
    func bothExpiryCodes() {
        for raw in [201, 208] {
            let code = ModuleMessageCode.classify(raw)
            #expect(code.isSessionExpired, "\(raw) must read as expired")
            #expect(code.isCredentialFailure == false)
        }
    }

    @Test("an unmapped code is carried verbatim, never rounded to a known one")
    func unmappedCodesAreCarried() {
        for raw in [0, 99, 102, 207, 209, 999, -1] {
            let code = ModuleMessageCode.classify(raw)
            #expect(code == .unrecognized(raw))
            #expect(code.rawCode == raw)
            #expect(code.isSuccess == false)
            #expect(code.isSessionExpired == false)
            #expect(code.isCredentialFailure == false)
        }
    }

    @Test("classification round-trips through the raw code")
    func classificationRoundTrips() {
        for raw in [100, 101, 201, 208, 999] {
            #expect(ModuleMessageCode.classify(ModuleMessageCode.classify(raw).rawCode)
                == ModuleMessageCode.classify(raw))
        }
    }

    @Test("the three failure classes are mutually exclusive")
    func classesAreExclusive() {
        let success = ModuleMessageCode.classify(100)
        let credentials = ModuleMessageCode.classify(101)
        let expiry = ModuleMessageCode.classify(208)

        #expect(Set([success, credentials, expiry]).count == 3)
        #expect(Set([success.isSuccess, credentials.isCredentialFailure, expiry.isSessionExpired])
            == [true])
    }

    @Test("a code renders as its number and carries nothing else")
    func codesRenderAsNumbers() {
        #expect(ModuleMessageCode.classify(208).description == "208")
        #expect(ModuleMessageCode.classify(999).description == "999")
    }
}
