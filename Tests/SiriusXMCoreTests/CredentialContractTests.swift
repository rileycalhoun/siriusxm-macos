import Foundation
import Testing

@testable import SiriusXMCore

/// The credential contract, and the two rules that make it safe to depend on.
@Suite("Credential provider contract")
struct CredentialContractTests {
    // MARK: - The password has nowhere to go

    @Test("no type that crosses the credential boundary has a password field")
    func passwordHasNoField() {
        // Reflection is used deliberately: the invariant is about the stored
        // properties of the boundary types, not about the values. A test
        // written in terms of values would keep passing after someone added a
        // `password` property that happened to be nil in this fixture.
        let session = SessionMaterial(token: "t", gupID: "g")
        let boundaryValues: [Any] = [
            session,
            CredentialError.unavailable(detail: "d"),
            CredentialError.rateLimited(retryAfterSeconds: 1),
            CredentialError.retryBudgetExhausted(attempts: 3),
            SessionExpirySignal.edgeGatewayUnauthorized(statusCode: 401),
            SessionExpirySignal.clockExpired(at: Date()),
            AuthenticationState.awaitingHuman(reason: .signInRequired),
            AuthenticationState.unavailable(detail: "d")
        ]

        for value in boundaryValues {
            for child in Mirror(reflecting: value).children {
                let label = child.label?.lowercased() ?? ""
                #expect(!label.contains("password"))
                #expect(!label.contains("passphrase"))
                #expect(!label.contains("secret"))
                #expect(!label.contains("credential"))
            }
        }
    }

    @Test("a session is a token and a device id and nothing else")
    func sessionCarriesOnlyResolvedCredentials() {
        let session = SessionMaterial(token: "t", gupID: "g")

        #expect(session.resolvedToken == "t")
        #expect(session.resolvedGupID == "g")
        #expect(Mirror(reflecting: session).children.count == 6)
    }

    @Test("a credential error renders a slug, never a body")
    func credentialErrorRendersASlug() {
        let rendered = CredentialError.unavailable(detail: "edge-gateway-401").description

        #expect(rendered == "unavailable(edge-gateway-401)")
        #expect(!rendered.contains("http://"))
    }

    @Test("the rate-limited error carries a whole number of seconds or nothing")
    func rateLimitedCarriesAnOptionalInterval() {
        #expect(CredentialError.rateLimited(retryAfterSeconds: 30).description == "rate-limited(30)")
        #expect(CredentialError.rateLimited(retryAfterSeconds: nil).description == "rate-limited(unspecified)")
    }

    @Test("human-sign-in reasons are all reasons a person can act on")
    func humanReasonsAreActionable() {
        let reasons: [HumanSignInReason] = [
            .signInRequired,
            .additionalVerificationRequired,
            .challengeIssued,
            .credentialRejected
        ]

        #expect(reasons.count == Set(reasons).count)
        for reason in reasons {
            #expect(!reason.description.isEmpty)
            #expect(!reason.description.contains(" "))
        }
    }

    // MARK: - Expiry is a value

    @Test("every expiry signal renders a short slug")
    func expirySignalsRenderSlugs() {
        #expect(SessionExpirySignal.edgeGatewayUnauthorized(statusCode: 401).description == "edge-gateway-401")
        #expect(SessionExpirySignal.moduleMessageCode(code: 208).description == "module-code-208")
        #expect(SessionExpirySignal.clockExpired(at: Date()).description == "clock-expired")
        #expect(SessionExpirySignal.revoked.description == "revoked")
    }

    @Test("an expiry signal never renders a date")
    func expirySignalsNeverRenderDates() {
        let rendered = SessionExpirySignal.clockExpired(at: Date(timeIntervalSince1970: 1_700_000_000)).description

        #expect(rendered == "clock-expired")
        #expect(!rendered.contains("1700000000"))
    }

    // MARK: - State transitions

    @Test("the six states are distinguishable and exactly one carries a session")
    func statesAreDistinguishable() {
        let states: [AuthenticationState] = [
            .signedOut,
            .awaitingHuman(reason: .signInRequired),
            .acquiring,
            .signedIn,
            .expired,
            .unavailable(detail: "no-network")
        ]

        #expect(states.count == Set(states).count)
        #expect(states.filter(\.hasSession).count == 1)
        #expect(states.filter(\.isBusy).count == 1)
        #expect(states.filter(\.needsUserAction).count == 1)
    }

    @Test("an expiry signal moves the app to acquiring, not to signed out")
    func expiryMovesToAcquiring() {
        let expired = AuthenticationState.signedIn.expired(by: .edgeGatewayUnauthorized(statusCode: 401))

        #expect(expired == .acquiring)
        #expect(!expired.hasSession)
    }

    @Test("no state slug leaks a payload")
    func stateSlugsAreSafe() {
        #expect(AuthenticationState.unavailable(detail: "no-network").slug == "unavailable")
        #expect(AuthenticationState.awaitingHuman(reason: .challengeIssued).slug == "awaiting-human(challenge-issued)")
        #expect(AuthenticationState.signedIn.slug == "signed-in")
    }
}

/// The keychain policy is the one place where "biometric gating on a background
/// refresh" could be introduced by accident, so both invariants are asserted
/// rather than described.
@Suite("Keychain accessibility policy")
struct KeychainAccessibilityPolicyTests {
    @Test("background token refresh is allowed to read the item")
    func backgroundAccessIsAllowed() {
        #expect(KeychainAccessibilityPolicy.afterFirstUnlockThisDeviceOnly.allowsBackgroundAccess)
    }

    @Test("no biometric or passcode gate is ever requested")
    func userPresenceIsNeverRequired() {
        #expect(!KeychainAccessibilityPolicy.afterFirstUnlockThisDeviceOnly.requiresUserPresence)
    }

    @Test("the policy has exactly one case, so there is nothing to choose wrongly")
    func thePolicyHasOneCase() {
        // A switch over the single case is the assertion: adding a second case
        // fails to compile until the two booleans above are re-examined.
        switch KeychainAccessibilityPolicy.afterFirstUnlockThisDeviceOnly {
        case .afterFirstUnlockThisDeviceOnly:
            break
        }
    }
}

/// Channels and guide entries are the first values the UI will render, so they
/// are pinned down before any view exists to depend on them.
@Suite("Channel and guide values")
struct ChannelAndGuideTests {
    @Test("a channel identifies by catalog id, not by display number")
    func channelIdentityIsTheCatalogID() {
        let channel = Channel(id: "sxm:channel-17", name: "Channel 17", number: 17, category: .music)

        #expect(channel.id == "sxm:channel-17")
        #expect(channel.description == "Channel(sxm:channel-17, Channel 17)")
    }

    @Test("a channel with no display number is still a channel")
    func channelNumberIsOptional() {
        let channel = Channel(id: "sxm:talk", name: "SiriusXM Talk", category: .talk)

        #expect(channel.number == nil)
        #expect(channel.shortDescription == nil)
        #expect(channel.artwork == nil)
    }

    @Test("a channel description never renders artwork")
    func channelDescriptionOmitsArtwork() {
        let channel = Channel(
            id: "sxm:channel-17",
            name: "Channel 17",
            category: .music,
            artwork: RedactingURL(string: "https://images.example.invalid/a.jpg?token=SECRET")!
        )

        #expect(!String(describing: channel).contains("SECRET"))
        #expect(!String(reflecting: channel).contains("SECRET"))
    }

    @Test("the category taxonomy is the provisional one, and is closed")
    func categoryTaxonomyIsClosed() {
        #expect(ChannelCategory.allCases == [.music, .news, .sports, .talk, .weather])
        #expect(ChannelCategory.music.description == "music")
    }

    @Test("an always-live channel has no window to seek within")
    func liveChannelHasNoWindow() {
        let entry = GuideEntry(
            id: "guide:1",
            channelID: "sxm:channel-17",
            title: "Continuous music",
            availability: .alwaysLive
        )

        #expect(entry.isLive)
        #expect(entry.window == nil)
        #expect(entry.artist == nil)
    }

    @Test("a scheduled programme exposes its window and is not live")
    func scheduledEntryHasAWindow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_003_600)
        let entry = GuideEntry(
            id: "guide:2",
            channelID: "sxm:channel-17",
            title: "Deep Cuts",
            artist: "Various",
            availability: .scheduled(startsAt: start, endsAt: end)
        )

        #expect(!entry.isLive)
        #expect(entry.window?.start == start)
        #expect(entry.window?.end == end)
        #expect(entry.artist == "Various")
    }

    @Test("an unknown availability is neither live nor a window")
    func unknownAvailabilityIsEmpty() {
        let entry = GuideEntry(id: "guide:3", channelID: "c", title: "t", availability: .unknown)

        #expect(!entry.isLive)
        #expect(entry.window == nil)
    }
}
