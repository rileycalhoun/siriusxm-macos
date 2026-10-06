# F1 — path-embedded secret redaction in `RedactingURL`

Branch: `fix/f1-path-redaction`
Base: `origin/fix/phase-0-defects` @ `8c7560a`
Files touched: `Sources/SiriusXMCore/RedactingURL.swift`,
`Tests/SiriusXMCoreTests/RedactingURLTests.swift`, and this file. Nothing else.

---

## 1. The defect

`RedactingURL` is the app's only defence against SiriusXM media credentials
reaching a log. It had two holes, both in the path:

* `render` built its output as `scheme://[userinfo@]host[:port]` +
  **`url.path` verbatim** + redacted query + redacted fragment.
* `carriesSensitiveComponents` was `url.query != nil || url.fragment != nil ||
  url.user != nil || url.password != nil`.

So a URL whose credential sits in the path was classified **clean** and
printed in full. This is not hypothetical: signed-media gateways do exactly
this, and the brief's example — `/v1/stream/9f3c1b7e2a4d/playback.m3u8` — is
one. Below is that URL rendered by the code at the base commit, captured by
running it, not by reading it:

```
https://live.example.invalid/v1/stream/9f3c1b7e2a4d/playback.m3u8|clean
```

`clean` is the second half of the defect: any debug-build assertion on
`carriesSensitiveComponents` would have passed on a URL that was about to
publish the credential.

---

## 2. The classification rule, in prose

The path is rendered **segment by segment**. Each segment is split from the
next on `/`, and a leading slash, an empty segment and a trailing slash all
survive, because splitting on `/` and rejoining on `/` is the identity when
nothing is redacted.

**Step 1 — take the core.** Peel a trailing *content* extension off the
segment. "Content extension" means a member of a fixed allowlist:

```
m3u8 ts aac m4a m4s mp3 mp4 aif aiff wav          (media)
jpg jpeg png gif webp svg                        (images)
json txt html htm xml css js vtt key             (text and scripts)
```

Only the **last** dot is considered, and only when the dot is not the segment's
first character. The result is the segment's **core**; a segment with no known
extension is its own core.

**Step 2 — the floor.** A core shorter than **12 characters** is structural,
full stop. It is not considered further. Every route word this app knows is
under the floor — `v1`, `player`, `sessions`, `playback`, `channel-17` — so
ordinary paths never reach step 3, and short path components are never at
risk.

**Step 3 — the three lexical escapes.** A core at or over the floor is
**opaque** (and therefore redacted) *unless all three* of these hold, which
together mean "somebody wrote this down by hand":

1. It contains **no uppercase ASCII letter.**
   `authentication` is 14 characters long and survives on this clause alone.
2. It is **not entirely hexadecimal.**
   `deadbeefcafe` has one run of eight lowercase letters and is still a digest.
3. It **spells something**: some run of four or more consecutive ASCII
   lowercase letters. A random blob's letters arrive in runs too short to be a
   word — `9f3c1b7e2a4d` has a longest run of one, `abc123def456` has three.

The three clauses between them catch the three shapes a credential actually
takes: a **hex digest** (clause 2, or clause 3), a **base64/UUID blob**
(mixed case, clause 1; or letters in short runs, clause 3), and an **all-caps
token** (clause 1). A path segment is none of those things.

**Step 4 — keep the extension.** When a segment *is* opaque *and* ends in a
known content extension, the extension survives the redaction:
`9f3c1b7e2a4d.m3u8` renders as `<redacted>.m3u8`. A log line that still says
"manifest" is worth more than one that says nothing at all.

The rule is a pure function of the segment string. It is not string stripping,
it consults no allowlist of known secrets, and it cannot be defeated by moving
a secret from the query into a path segment — which is precisely the move it
exists to catch.

### The trade, named

The rule is deliberately conservative, and the gap is worth stating plainly:
**a path secret shorter than 12 characters, or one spelled in lowercase words,
is not caught.** A rule loose enough to catch every possible short secret
would have to redact `authentication`, `subscriptions`, and
`segment-000012` — which is the over-redaction criterion 3 forbids. Every
credential this app actually holds (a bearer token, a gupId, an `SXMAKTOKEN`)
is far longer than the floor and is not word-shaped, and the query redaction
is the belt to these braces.

Two further consequences worth knowing:

* **Unknown extensions are not peeled.** `9f3c1b7e2a4d.bin` is judged whole,
  so the whole segment including `.bin` is replaced. That is the safe
  direction, and it is asserted in a test rather than left implicit.
* **Non-ASCII is not "spelled".** A segment containing a non-ASCII character
  breaks every lowercase run (clause 3) and so tends toward opaque. Also the
  safe direction.

---

## 3. Before and after

Captured by running both versions of the file against the same list of URLs
(scratch executable, `swift run`, Swift 6.1.3). `|` separates the rendering
from `carriesSensitiveComponents`.

| URL | Before (`origin/fix/phase-0-defects`) | After |
|---|---|---|
| `/9f3c1b7e2a4d/v1/track.m3u8` | `…/9f3c1b7e2a4d/v1/track.m3u8` `clean` | `…/<redacted>/v1/track.m3u8` `sensitive` |
| `/v1/9f3c1b7e2a4d/stream/playback.m3u8` | `…/v1/9f3c1b7e2a4d/stream/playback.m3u8` `clean` | `…/v1/<redacted>/stream/playback.m3u8` `sensitive` |
| `/hls/live/9f3c1b7e2a4d` | `…/hls/live/9f3c1b7e2a4d` `clean` | `…/hls/live/<redacted>` `sensitive` |
| `/hls/live/9f3c1b7e2a4d.m3u8` | `…/hls/live/9f3c1b7e2a4d.m3u8` `clean` | `…/hls/live/<redacted>.m3u8` `sensitive` |
| `/v1/Zm9vYmFyYmF6cXV4/track.aac` | `…/v1/Zm9vYmFyYmF6cXV4/track.aac` `clean` | `…/v1/<redacted>/track.aac` `sensitive` |
| `/v1/qm9x8k2zp4nr/track.aac` | `…/v1/qm9x8k2zp4nr/track.aac` `clean` | `…/v1/<redacted>/track.aac` `sensitive` |
| `/v1/stream/9f3c1b7e2a4d/track.m3u8?consumer=k2&token=…` | `…/v1/stream/9f3c1b7e2a4d/track.m3u8?<redacted>` `sensitive` | `…/v1/stream/<redacted>/track.m3u8?<redacted>` `sensitive` |
| `/v1/stream/9f3c1b7e2a4d/playback.m3u8` | `…/v1/stream/9f3c1b7e2a4d/playback.m3u8` `clean` | `…/v1/stream/<redacted>/playback.m3u8` `sensitive` |
| `/session/v1/sessions/refresh` | unchanged `clean` | unchanged `clean` |
| `/profile/v4/profiles/me` | unchanged `clean` | unchanged `clean` |
| `/rest/v2/experience/modules/modify/authentication` | unchanged `clean` | unchanged `clean` |
| `/hls/v1/channel-17/master.m3u8` | unchanged `clean` | unchanged `clean` |
| `/hls/v1/channel-17/segment-000012.aac` | unchanged `clean` | unchanged `clean` |
| `/art/channel-17.jpg` | unchanged `clean` | unchanged `clean` |
| `https://player.siriusxm.com` (no path) | unchanged `clean` | unchanged `clean` |

Read the last seven rows as the criterion-3 evidence: **not one ordinary
address changed, and none of them started reporting `sensitive`.**
`authentication` (14 chars), `subscription`/`subscriptions` (12/13) and
`segment-000012` (13) all sit above the floor and survive only because of
clause 1 and clause 3 — they are the cases a naive length rule gets wrong.

---

## 4. API changes

Additions only. No public signature was altered, so `SiriusXMNet` and
`SiriusXMProtocol` compile and behave unchanged.

| Member | Kind | Note |
|---|---|---|
| `public var path: String` | **kept**, doc changed | Behaviour identical. Now documented as a **leak site on the same footing as `resolvedURL`**, not as a safe accessor beside `scheme`/`host`. |
| `public var carriesSensitiveComponents: Bool` | behaviour changed | Now also true when a path segment is opaque. |
| `static let minimumOpaqueLength: Int` | added, internal | The floor, as a named constant so a test can assert the boundary instead of restating `12`. |
| `static func redactedPath(_:) -> String` | added, internal | The path renderer; tested directly. |
| `static func isOpaque(_:) -> Bool` | added, internal | The rule; tested directly, so the rule is testable without going through `URL`. |
| `static func render(_:)` | **unchanged signature** | Now calls `redactedPath`. |

---

## 5. Tests

**237 → 262** (26 added, 1 renamed-and-strengthened).

### Path credential in every position

* `a credential in the first path segment is redacted`
* `a credential in a middle path segment is redacted`
* `a credential in the last path segment, before the extension is redacted`
* `a credential in the last, bare, path segment is redacted`
* `a credential segment keeps its extension, because the extension is not the credential`
* `every credential in the path is redacted, not just the first`

### Credential shapes

* `a base64 credential in the path is redacted`
* `an all-caps credential in the path is redacted`
* `a credential whose letters never spell a word is redacted`

### The flag

* `the sensitive-component flag is true for a path credential in any position`
  — eight candidate URLs, one per position and shape.
* `the flag is exactly the set of components that were replaced` — asserts
  `carriesSensitiveComponents == description.contains("<redacted>")` for clean
  paths, path-secret paths, query, and fragment. This is the invariant that
  makes the flag trustworthy rather than merely non-empty.

### Every description path, for a path credential

* `every description path is closed for a path credential` — one URL pushed
  through `description`, `debugDescription`, interpolation, a plain struct,
  a reflecting struct, an array, a dictionary, `Optional`, and `Any`. Each
  rendering is asserted **non-empty** as well as secret-free, so a rendering
  that produced nothing cannot pass.
* `redaction is presentational: the address still carries the path credential`
  — `resolvedURL` and `path` still return the real secret, so request
  building is untouched.

### Reflection (the header's missing coverage)

* `dump() renders no path-embedded credential` — **new**, and asserts the sink
  contains `<redacted>`, not merely that it lacks the secret.
* `dump() of a value nested in something else renders no path credential` —
  **new**, a `struct Holder` so the recursive walk is exercised, not just the
  top-level node.
* `Mirror exposes no child carrying a path-embedded credential` — **new**.
* `Mirror exposes no URL for a path-embedded credential either` — **new**.

### The vacuous-assertion guard

`mirrorExposesNoURL` was a `for child in mirror.children { #expect(!(child.value
is URL)) }` with nothing asserting the list was non-empty: a `customMirror`
that returned no children would have passed without executing its assertion
once. It now asserts `#expect(!url.description.isEmpty)` before reflecting —
the mirror's children are both derived from the rendered form, so an empty
rendering would mean an empty mirror — and then
`#expect(!mirror.children.isEmpty, "an empty mirror makes this test vacuous")`
before the loop.

### Regression: ordinary URLs still render usefully

* `a path with no secret in it renders in full` — eleven addresses: every
  endpoint this app actually builds (`session/v1/sessions/refresh`,
  `profile/v4/profiles/me`, `subscription/v1/subscriptions`,
  `rest/v2/experience/modules/modify/authentication`, `…/resume`,
  `www.siriusxm.com/player`) plus CDN media and artwork shapes
  (`master.m3u8`, `segment-000012.aac`, `segment.part00001.ts`,
  `channel-17.jpg`, `channel-17-1280x1280.jpg`). Each is asserted to render
  **byte-identical to its input** and to report `!carriesSensitiveComponents`.
* `a query credential does not cost the path its rendering`
* `a URL with no path renders without one`
* `redacting the path leaves its shape alone`

### The rule itself

* `the rule is a length floor and three lexical escapes` — five opaque and
  seven structural cores, named inline with the clause that decides each.
* `the floor is the boundary, and it is the rule's own constant` — asserts
  `minimumOpaqueLength == 12`, that a hex digest one character under it
  survives, and that the same digest on it does not.
* `only a known content extension is peeled off before judging` — known
  extension kept, unknown extension not peeled, only the last dot peeled.

### The header comment

The file header claimed *"The two tests under 'Reflection' below cover that
path"*. There were three, and it made no mention that `dump()` coverage
existed at all. It now states that Reflection is covered by four tests, says
which four, and records that the first two would pass vacuously against an
empty mirror — so the next reader knows the guard is load-bearing rather than
redundant. It also now explains the two path sections.

### Proof the new tests are not vacuous

With the fix reverted in place (two lines: `text += url.path` and dropping the
path clause from the flag) and everything else held constant:

```
swift test  →  Test run with 262 tests failed after 0.051 seconds with 42 issues
```

17 of the new tests fail, plus the strengthened `read accessors` test. The
ones that keep passing are the ones that *should*: the false-positive guards
(`a path with no secret in it renders in full`, `queryRedactionLeavesThePathAlone`,
`emptyPathIsLeftAlone`), the direct rule tests (`classificationRuleIsStated`,
`classificationFloorIsExact`, `onlyKnownExtensionsArePeeled`), and
`sensitiveFlagMatchesWhatWasRedacted` — which is a *consistency* check between
the flag and the rendering, so it correctly agrees with the broken renderer
that neither is redacting. That is the intended behaviour of that test, not a
gap in it.

---

## 6. Build and test

**Command** (run from the repo root, branch `fix/f1-path-redaction`):

```
export PATH=/opt/swift/usr/bin:$PATH
swift build
swift test
```

**Toolchain:** Swift 6.1.3 (`swift-6.1.3-RELEASE`), target
`x86_64-unknown-linux-gnu`.

| | command output |
|---|---|
| Baseline, `origin/fix/phase-0-defects` | `Test run with 237 tests passed after 0.047 seconds.` |
| After, `fix/f1-path-redaction` | `Test run with 262 tests passed after 0.049 seconds.` |
| Build | `Build complete!` — no warnings, no errors |

`swift build` covers all six targets and `swift test` all four test targets.
The baseline figure of **237** matches the figure given in the brief exactly,
which is the evidence that this Linux run is exercising the same suite the
macOS gate does.

### Deviation from "on macOS" — stated, not hidden

**Criterion 6 asked for a macOS run and I could not perform one.** Not
because of anything in the code:

* This container is Linux and has no macOS SDK. It does have a Swift 6.1.3
  Linux toolchain at `/opt/swift/usr/bin`, which is what produced the numbers
  above.
* `kane` (the Mac mini) is the macOS gate, and the tree at
  `/Users/rileycalhoun/SandboxBuilds/SiriusXM` is **empty of source**:
  `ssh kane "/Users/rileycalhoun/SandboxBuilds/SiriusXM swift test"` answers
  `error: Could not find Package.swift in this directory or any of its parent
  directories.` That is the stale/empty-staging failure mode the restage
  helper is known to produce when kane's source checkout is not on the branch
  under test.
* Staging is `sudo /usr/local/bin/xcode-sandbox-restage-sxm`, run by a human
  on kane. The sandbox wrapper on kane allows only `xcodebuild`, `xcrun`,
  `swift`, `swiftc`, `clang`, `cargo`, `rustc`, `python3` — no `git`, no
  `scp` — so the branch cannot be moved there from here, and I did not try to
  route around the sandbox to do it.

To close this on macOS, on kane:

```
cd /Users/rileycalhoun/siriusxm-macos
git fetch origin fix/f1-path-redaction
git checkout fix/f1-path-redaction && git pull --ff-only
sudo /usr/local/bin/xcode-sandbox-restage-sxm
ssh kane "/Users/rileycalhoun/SandboxBuilds/SiriusXM swift test"
```

Expect `Test run with 262 tests passed`. The one place to watch is
`URL.path` and trailing slashes — see the note below.

### A platform difference the tests now route around

`pathShapeSurvivesRedaction` asserts trailing-slash behaviour against
`redactedPath` directly rather than through a `URL`, because swift-corelibs
Foundation strips a trailing slash from `URL.path` while Darwin's keeps it.
The redaction itself must not be what normalises it, so the assertion belongs
on the string function. This is the same reasoning the pre-existing
`unparseableStringYieldsNothing` test already used for a Foundation
difference, and it means the suite is green on both platforms.

---

## 7. Deliberately left out

* **`RetryPolicy.swift`, `RetryingTransport.swift`, `HTTPTransport.swift`,
  `HTTPResponse.swift`** — out of scope, a parallel unit owns them. Untouched.
* **The shared checkout at `/projects/siriusxm-macos`** — not used. All work
  happened in `/tmp/agent-shared/f1-redaction`, a fresh clone from
  `origin/fix/phase-0-defects`, so the unrelated dirty
  `Tests/SiriusXMProbeTests/` → `Tests/SiriusXMProtocolTests/` rename cannot
  reach this diff.
* **`Codable`/`RawRepresentable`/string initialiser** — still omitted, and the
  reasons in the type's doc comment still hold. Path redaction does not change
  them.
* **An entropy measure** (Shannon entropy over a character histogram) was
  considered and rejected. It would have caught short lowercase word-like
  secrets, but its threshold is a distribution estimate, so its behaviour on a
  given segment would depend on calibration rather than on a rule, and it
  cannot be asserted as exactly in a test. The length floor plus three lexical
  escapes is deterministic at every input.
* **A `[String: Bool]` allowlist of known credential prefixes** (`gupId`,
  `token`, `session=`) was considered for the path. Rejected: a path credential
  carries no such marker, so an allowlist would not fire on the actual case,
  and it would add a maintenance burden to a security primitive.
* **Calling the new rule from `RequestFingerprint`** — not needed. The
  fingerprint already renders through `RedactingURL`, so it inherits path
  redaction for free, and two requests that differed only in a path credential
  now share a fingerprint, which is the documented intent of that type.
* **Cross-platform macOS verification** — see §6.

---

## 8. Residual risk, stated

1. **Path secrets under 12 characters, or spelled in lowercase words, are not
   redacted.** Named trade, argued in §2.
2. **The floor is 12 because `authentication` is 14 and `subscriptions` is
   13.** Any future route word longer than the floor relies on clauses 1 and 3
   rather than on the floor. A new endpoint whose path segment is a long
   *uppercase* or *mixed-case* word would be redacted — loudly, safely, and
   visibly, which is the intended direction, but it would be a false positive
   worth a look if it ever happens.
3. **`path` and `resolvedURL` still hand out the raw path.** Both are
   documented as leak sites now. Nothing in the package calls
   `RedactingURL.path`; `grep` over `Sources/` shows one definition and no use
   outside tests.
