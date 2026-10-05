# Phase 0.5 — How can SiriusXM session credentials actually be acquired?

## What this document is

A research spike. No audio, no playback, no UI, no app scaffolding. The question
answered here is narrow and it is the one that gates the entire project:

> Given a subscriber's own username and password, can a native macOS client obtain a
> usable session — and if so, which session, obtained how?

Every claim below carries a confidence marker.

| Marker | Meaning |
| --- | --- |
| **CONFIRMED** | Observed directly in a live HTTP response during this probe, with no credential. Reproducible by running the harness. |
| **INFERRED** | Derived from the shipped reference implementation or from protocol reasoning. Consistent with everything observed, but not itself observed here. |
| **UNKNOWN** | Not determined. Requires the credentialed run. |

No endpoint is named as working unless it appeared in a response. Where an endpoint is
named only because the reference implementation calls it, that is stated explicitly.

## How the evidence was produced

`SiriusXMProbe` is a standalone SwiftPM executable. Run with no credentials it performs
five credential-free requests against production and parses every response. It never
prints a token, a cookie value, or a URL with a query string; a `Redactor` sits in front
of the report writer and a source-scan-free unit suite asserts that no secret type leaks
through `String(describing:)` or `String(reflecting:)`.

```console
$ swift run SiriusXMProbe
credential-gated paths: SKIPPED
  missing environment variable(s): SXM_USERNAME, SXM_PASSWORD
  export them in the shell to run the credentialed paths.
  do not pass credentials on the command line; argv is world-readable via ps.

path | result | statusCode | acquired | notes
--- | --- | --- | --- | ---
edge-shape-profile-me | observed | 401 | false | GET profile v4 me, no authorization header; body=empty; cookies=0
edge-shape-subscriptions | observed | 401 | false | GET subscription v1 subscriptions, no authorization header; body=empty; cookies=0
edge-shape-session-refresh | observed | 401 | false | POST session v1 sessions refresh, location null, no refresh cookie; body=empty; cookies=0
module-shape-auth-unauthenticated | observed | 200 | false | POST modify authentication, deviceInfo only, no standardAuth; body=json; cookies=0; moduleStatus=not-1; messageCode=101
module-shape-resume-unauthenticated | observed | 200 | false | POST resume with OAtrial false, no session cookies; body=json; cookies=2; moduleStatus=not-1; messageCode=201
module-auth-programmatic | skipped-no-credential | - | false | legacy module API sign-in; requires SXM_USERNAME and SXM_PASSWORD in the environment
module-resume-programmatic | skipped-no-credential | - | false | replays the cookie set from module-auth-programmatic; requires SXM_USERNAME and SXM_PASSWORD in the environment
module-token-on-edge-gateway | skipped-no-credential | - | false | presents the legacy AK token as an edge-gateway bearer; requires SXM_USERNAME and SXM_PASSWORD in the environment
edge-session-refresh-grant | blocked | - | false | endpoint exists and refuses anonymous calls; refresh requires an existing sxm-refresh-token cookie issued by an interactive sign-in; this harness will not mint one
web-auth-token-cookie | documented | - | false | browser entry point is a plain path on www.siriusxm.com, no query string; requires a human-operated sign-in; the resulting first-party AUTH_TOKEN cookie carries the edge-gateway access token

summary: 10 paths, 5 observed anonymously, 0 acquired a session
```

`skipped-no-credential` is a first-class result, not an error. The probe is designed so
that the honest no-credential outcome is a normal, reported, successful run.

## Candidate path results

### Path A — programmatic sign-in via the legacy cookie module API

**Status: shape CONFIRMED live, acquisition UNKNOWN pending the credentialed run.**

Request construction (`ProbeEndpoint.moduleBody`) is verified to produce the documented
envelope. Confirmed against the live service only in its *unauthenticated* form:

```
POST /rest/v2/experience/modules/modify/authentication
Content-Type: application/json

{
  "moduleList": { "modules": [ {
    "moduleName": "login",
    "moduleRequest": {
      "resultTemplate": "login",
      "deviceInfo": {
        "appRegion": "US", "browser": ..., "browserVersion": ...,
        "clientDeviceId": "null", "clientDeviceType": "web",
        "deviceModel": "K2WebClient", "osVersion": ...,
        "platform": "Web", "player": "html5", "sxmAppVersion": ...
      },
      "standardAuth": { "username": "...", "password": "..." }
    }
  } ] }
}
```

Response with `standardAuth` omitted:

- **CONFIRMED** — HTTP **200**.
- **CONFIRMED** — `ModuleListResponse.status == 0` (not authenticated).
- **CONFIRMED** — message **code 101**, text `Bad username/password`.
- **CONFIRMED** — zero `Set-Cookie` headers.

Two observations that matter more than they look:

1. **CONFIRMED — the module API returns HTTP 200 even for a rejected credential.**
   Classification must therefore read `ModuleListResponse.status` and `messages[].code`.
   Any code that treats non-2xx as failure will read a *failed login as a transport
   error* and, worse, a *successful login as a failure* if the shape ever shifts.
2. **CONFIRMED — message code 101 exists and is not in the commonly cited table.**
   The 2015 and 2026 Python implementations document 100 / 201 / 208. Code 101
   (bad credentials) was not previously recorded. It is now mapped and unit-tested.

**UNKNOWN — whether this endpoint still grants a session at all.** The shape is stable
from 2015 through 2026 and the endpoint answered us on this date with a
credential-specific error rather than a deprecation error, which is weak positive
evidence that the grant path is alive. That is an inference, not a proof. The
`module-auth-programmatic` row answers it definitively.

If it does succeed, the expected yield (from the reference implementation and the Python
clients, **INFERRED**, not observed here) is cookies `SXMAUTH`, `SXMAKTOKEN`, `JSESSIONID`
and a URL-encoded `SXMDATA` carrying `gupId`. All four are parsed and unit-tested against
synthetic fixtures.

### Path B — a direct edge-gateway token grant

**Status: CONFIRMED that no anonymous grant endpoint exists. UNKNOWN whether any exists.**

Three edge-gateway operations were exercised with no `Authorization` header:

| Operation | Observed |
| --- | --- |
| `GET /profile/v4/profiles/me` | **CONFIRMED** — 401, empty body, no cookies |
| `GET /subscription/v1/subscriptions` | **CONFIRMED** — 401, empty body, no cookies |
| `POST /session/v1/sessions/refresh` | **CONFIRMED** — 401, empty body, no cookies |

**CONFIRMED** — the edge gateway is live and reachable, and it refuses every request that
does not already carry a Bearer token. There is no unauthenticated surface.

**CONFIRMED** — `/session/v1/sessions/refresh` is *renewal*, not *grant*. The reference
implementation calls it only to extend an already-authenticated session and expects a
pre-existing HttpOnly `sxm-refresh-token` cookie. The probe's request carried a `Location:
null` and no such cookie, and got a flat 401. This endpoint cannot bootstrap a session
from nothing. This is the single most useful negative result in the spike, because it is
the endpoint most likely to be mistaken for a grant.

**UNKNOWN** — whether some undocumented edge-gateway grant endpoint exists. No reference
implementation calls one, no credential-free probe can discover one by definition (an
unauthenticated call to a real grant endpoint is indistinguishable from a probe, and this
spike will not spray endpoints at a production auth service to find out).

### Path C — WKWebView sign-in

**Status: INFERRED as the only known-working route. Not attempted here.**

The shipped reference implementation (`gabeosx/canis97`, MIT) does not solve token
acquisition programmatically. It presents a non-persistent `WKWebView` at the first-party
player entry point, lets a human sign in, and then reads a **first-party `AUTH_TOKEN`
cookie** out of the cookie store.

- **INFERRED** — the `AUTH_TOKEN` cookie value *is* the edge-gateway Bearer token. The
  reference maps `session.accessToken` to the `Authorization` header it sends to
  `api.edge-gateway.siriusxm.com`. We did not observe this value.
- **INFERRED** — the browser entry point is a plain path on the first-party web host with
  no query string.
- **INFERRED** — cookie selection matters: the reference deliberately reads only
  `AUTH_TOKEN` and ignores everything else in the store.

Not attempted in this phase, for two reasons. First, the task scopes path C to cases
doable without a bundled credential, and a working implementation still needs a human to
type a password — there is no headless variant to build. Second, the reference
implementation's own attempt at programmatic extraction was recorded as inconclusive.

**UNKNOWN** — whether a clean, app-bound web sign-in currently completes reliably, and
what the sign-in flow does when the account has MFA enabled. MFA is a hard stop this
project will not attempt to work around.

## The finding

**There is no confirmed credential-free programmatic grant on either protocol generation,
and the only route known to work is browser-mediated.**

Stated precisely:

1. **CONFIRMED** — both service generations are live and reachable today.
2. **CONFIRMED** — both refuse unauthenticated requests. Neither offers an anonymous or
   password-grant surface that this probe could exercise.
3. **INFERRED** — a human-operated web sign-in yields an `AUTH_TOKEN` cookie that is the
   edge-gateway Bearer token. This is the reference implementation's approach and it
   ships to real users, so it works; but it is a claim about *their* app, not an
   observation we made.
4. **UNKNOWN** — whether the legacy module API still issues a full session from a correct
   username and password. If it does, a fully native sign-in exists and the web view is
   only a fallback.
5. **UNKNOWN** — whether a legacy `SXMAKTOKEN` is accepted by the edge gateway at all.
   The two sessions may be entirely separate credential generations. If they are, the
   legacy path buys us a session that cannot reach playback, and it is worthless for the
   modern API.

Points 4 and 5 are what `module-auth-programmatic` and `module-token-on-edge-gateway`
respectively exist to answer. Until they are answered, **the app must be built on the
assumption that token acquisition is browser-mediated**, because that is the only
mechanism with any evidence behind it.

### Which mechanism the app should use

**Use the browser-mediated edge-gateway token as the primary, and keep the legacy module
API as a researched fallback — but do not build the fallback until point 4 is answered.**

Reasoning:

- The edge gateway is where playback lives. A session that cannot reach
  `/playback/play/v1/tuneSource` is not a session worth having, whatever else it grants.
  This makes point 5 decisive: a legacy token that the gateway rejects buys nothing.
- The legacy API is the fallback only because its shape has demonstrably survived eleven
  years and two independent third-party implementations. That is real evidence about
  *stability of shape*, not about *availability of grant*.
- Building a native sign-in path first and discovering point 4 or 5 fails would mean
  rewriting the credential layer against a live service. Building it second costs one
  dependency injection seam.

The rule this suggests for Phase 0: **never let a `WKWebView` type leak past the
credential boundary.** The web view is a credential *source*, not a dependency. If a
`SessionMaterial` can be produced from it, everything downstream should be identical to
the case where it came from somewhere else — which is precisely the seam described below.

## Known unknowns, left for the credentialed run

Run by the operator, on their own account:

```console
export SXM_USERNAME='...'
export SXM_PASSWORD='...'
swift run SiriusXMProbe
```

The probe reads credentials from the environment only. Never from argv — `ps` is
world-readable — never from disk, and it never persists them.

Rows that change status:

| Row | Question it answers |
| --- | --- |
| `module-auth-programmatic` | Does `modify/authentication` still grant a session? Which cookies come back? |
| `module-resume-programmatic` | Does the granted cookie set actually resume a session, or does it immediately return 201/208? |
| `module-token-on-edge-gateway` | Is a legacy `SXMAKTOKEN` accepted as an edge-gateway Bearer? This is the point 5 question. |

Still unknown afterwards, and requiring a separate decision:

- Whether sign-in completes without human interaction for MFA-enabled accounts.
- The edge-gateway token's actual lifetime, and what `sxm-refresh-token` is required to
  renew it.
- Whether `standardAuth` sign-in trips account protection when called from a device
  fingerprint that differs from the subscriber's normal one. **This probe sends one
  stable fingerprint and never varies it.** If the operator's run triggers a security
  challenge, that is a finding to report, not something to engineer around.

## Implications for module design

**The app needs a `CredentialProvider` protocol, and at this moment exactly one
implementation.**

```swift
protocol CredentialProvider: Sendable {
    /// Returns a usable session, or throws. Never caches, never persists a password.
    func acquire() async throws -> SessionMaterial
    /// Extends an existing session in place. Takes no password.
    func refresh(_ session: SessionMaterial) async throws -> SessionMaterial
}
```

One implementation now — `WebSignInCredentialProvider`, wrapping the `WKWebView` flow —
and a protocol seam reserved for a possible `LegacyModuleCredentialProvider`.

What this buys and what it costs:

- It costs one interface and one dependency-injection edge. That is cheap, and it is the
  minimum amount of scaffolding needed to keep the browser dependency out of the domain.
- It buys the ability to answer point 4 later without touching anything downstream.
  `SessionMaterial` is already the currency; both providers produce it, and everything
  past the boundary is provider-agnostic by construction.
- It does **not** license a second implementation today. Writing `LegacyModuleCredentialProvider`
  now, against an unproven endpoint, is exactly the scaffolding lock-in this phase was
  meant to avoid.

Constraints the protocol shape must preserve:

- `acquire()` takes no arguments and reads no ambient global. A provider that reaches for
  `ProcessInfo` directly cannot be substituted or tested.
- The password exists only inside `acquire()`, as a local. It must never cross the
  protocol boundary, because `SessionMaterial` is the only thing that crosses it, and
  `SessionMaterial` has no field for a password.
- No caching of `acquire()` results outside the session layer. Caching a *session* is
  legitimate; caching a *password* is not, and nothing in Phase 0 should make it easy.

## What Phase 0 must account for

1. **Do not schedule a native sign-in as a known quantity.** Phase 0 plans that assume
   programmatic acquisition will collapse. If the credentialed run shows
   `modify/authentication` works *and* the gateway accepts the legacy token, that plan
   gets cheaper. If it shows otherwise, the browser path is the product, not a stopgap,
   and it needs a real UI, real error states, and a real session-expiry story.
2. **The `WKWebView` is a hard dependency of the primary path.** That is a genuine
   architectural fact, not an implementation detail. It means the app cannot be a pure
   URLSession client, it needs a window to host the web view, and it needs to survive the
   user navigating away mid-sign-in.
3. **Session expiry is not an edge case, it is the normal state.** Both generations
   signal it in-band — message 201/208 and HTTP 401 respectively. The credential provider
   must be re-enterable from the middle of a session, not just at launch.
4. **Bounded, fingerprint-stable retries.** Set in the project rules already; this spike
   reinforces it. The probe sends one stable `deviceInfo` and never varies it, and that
   is the behaviour the app should copy.
5. **Nothing in this document authorizes evasion.** No CAPTCHA bypass, no MFA bypass, no
   DRM circumvention, no device-ID rotation, no fingerprint variation. If the subscriber's
   account requires a step this client will not take, the correct outcome is a clear
   message to the user, not a workaround.

## Verification status

| Gate | Result |
| --- | --- |
| `swift build` | Pass, zero warnings |
| `swift test` | Pass, 68 tests, fully offline |
| Credential-free probe | Pass — 5 paths observed live, 3 skipped, 1 blocked, 1 documented |
| Credentialed probe | **Not run.** Requires the operator's own account |
| Redaction violation caught | **Proven.** See below |

Both gates were executed in a Linux Swift 6.1 container against the staged tree. The
project's designated macOS gate host could not be reached for staging in this
environment; see the phase report for the verbatim blocker. The code uses no
platform-specific API — `Foundation` and `FoundationNetworking` only — so the macOS
result is expected to match, but it has not been observed.

### Redaction and fixture hygiene are not vacuous

Both guards were proven by deliberately breaking them.

**Proof 1 — leak a secret through `description`.** `SessionMaterial.description` was
temporarily changed to interpolate the raw token instead of `<redacted>`. Three
independent tests failed:

```
✘ Test "a populated SessionMaterial leaks nothing to String(describing:)" recorded an issue
  at RedactionTests.swift:36:31
✘ Test "a populated SessionMaterial leaks nothing to String(reflecting:)" recorded an issue
  at RedactionTests.swift:45:31
✘ Test "interpolation and collection rendering stay redacted" recorded an issue
  at RedactionTests.swift:61:31
```

The failure surfaced the token through plain `print`, through nested struct rendering,
through a collection, and through string interpolation — which is what the guard is for.

**Proof 2 — put a token and a UUID into a fixture.** A JWT-shaped string and a
UUID-shaped string were added to `module-auth-success.json`. The hygiene scanner failed
on both patterns:

```
✘ Test "no fixture contains a token-shaped string" recorded an issue at FixtureHygieneTests.swift:31:31
✘ Test "no fixture contains a UUID" recorded an issue at FixtureHygieneTests.swift:36:31
✘ Test run with 68 tests failed after 0.012 seconds with 3 issues.
```

A third test, `the hygiene patterns still match known-bad samples`, asserts the scanner's
patterns against strings that *must* match. Without it, a typo in a regex would make
every hygiene test pass by never matching anything.

Both violations were reverted. The working tree was confirmed byte-identical to `HEAD`
and the suite returned to 68 passing tests.