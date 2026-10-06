# QA Audit: F1 Path-Secret Redaction

Read-only adversarial audit of `fix/f1-path-redaction` @ `d1e945f` (the fix)
plus test hardening `test/f1-nonvacuous-tests` @ `4ad4b4e`. Completed on branch
`qa/audit-f1-final`, resuming the skeleton pushed on
`qa/audit-f1-path-redaction` @ `85cf3fc`.

**Environment: Linux only.** Swift 6.1.3 (`swift-6.1.3-RELEASE`),
`x86_64-unknown-linux-gnu`, toolchain at `/opt/swift/usr/bin`.
**Nothing in this audit has compiled or run on macOS.** The app targets
macOS 14+ only; every macOS-facing statement below is analysis, not evidence,
and is marked as such.

## Status: COMPLETE

| Finding | Verdict |
|---|---|
| F1-1 Percent-encoding divergence | **REFUTED** as a defect on the shipping platform (premise inverted on this toolchain; direction of risk is safe) |
| F1-2 Vacuous assertions + false header | **CONFIRMED** as originally raised; **CONFIRMED CLOSED** by `4ad4b4e` |
| F1-3 `displayTarget` bypass | **CONFIRMED** as a bypass; **LOW severity**, not exploitable today; latent trap, accept with non-blocking follow-up |
| F1-4 Sub-12-char / word-shaped credentials | **Confirmed by design; ACCEPT the trade** |
| New defects from `4ad4b4e` | **NONE FOUND** |

**Final verdict: ACCEPT.** No blocker. One non-blocking hardening
recommendation (F1-3).

---

## Method

Fresh clone from `origin` into `/tmp/agent-shared/sxm-qa-audit` (the shared
checkout at `/projects/siriusxm-macos` was not touched). Branch
`qa/audit-f1-final` created at `4ad4b4e`. All adversarial harness code lived in
`/tmp/agent-shared/qa-scratch/`, **outside the repo tree**, and was compiled
against a copy of `Sources/SiriusXMCore/RedactingURL.swift`. The repo tree was
never in a committed state that contained scratch files (see "Workspace
hygiene").

Baseline runs at `4ad4b4e`:

```
swift build  → Build complete! (6.50s), no warnings
swift test   → ✔ Test run with 263 tests passed after 0.049 seconds.
```

263 = the fix branch's documented 262 plus the one new test
(`emptinessGuardRejectsAnEmptyMirror`) from `4ad4b4e`. Consistent with the
fix doc at `docs/f1-path-secret-redaction.md` §6.

### Revert-experiment (fix doc §5 claims 17 new test failures, 42 issues)

Reproduced with the doc's stated procedure: keep the new API surface, revert
only the two behaviour lines (`text += redactedPath(url.path)` →
`text += url.path`; drop the path clause from `carriesSensitiveComponents`).
Result on Linux:

```
✘ Test run with 263 tests failed after 0.054 seconds with 42 issues.
```

**Exactly 42 issues, as claimed.** 18 distinct tests fail: the 17 new path
tests plus the strengthened `read accessors report the parts, and path is the
raw one` (RedactingURLTests.swift:446). The consistency-only test
`sensitiveFlagMatchesWhatWasRedacted` and the false-positive guards pass under
the revert, as the doc says they should. The claim is **confirmed**.
(The file was restored immediately after; final tree is clean and green,
263 passing.)

---

## F1-1 Percent-encoding divergence — REFUTED as a shipping-platform defect

**Claim as raised:** `url.path` percent-DECODES on swift-corelibs (Linux) but
preserves encoding on Darwin, so `redactedPath(url.path)` sees a different
string per platform.

**Evidence (Linux, Swift 6.1.3, scratch harness `f1_probe.swift`):**

```
https://h.invalid/v1/t%6Fken%62lob/x.m3u8  ->  path=/v1/tokenblob/x.m3u8
https://h.invalid/v1/%39f3c1b7e2a4d/x.m3u8 ->  path=/v1/9f3c1b7e2a4d/x.m3u8
```

So on this toolchain Linux `URL.path` **decodes** general percent-escapes.
But the claim's premise has two problems:

1. **The premise is inverted for modern Foundation.** Darwin's `NSURL.path` is
   documented to return the percent-decoded path (the raw form requires
   `percentEncodedPath` / `path(percentEncoded: true)`). The claimed divergence
   ("Linux decodes, Darwin preserves") was true of *old* swift-corelibs bugs;
   swift-foundation on Linux 6.1.3 exhibits Darwin's documented semantics. The
   shipping platform was never running the "preserving" implementation
   described in the finding.
2. **The divergence that actually survives is narrow and safe-direction.**
   Probing the real `RedactingURL` with encoded path secrets on Linux:

```
in : .../v1/stream/9f3c%31b7e2a4d/playback.m3u8
out: .../v1/stream/<redacted>/playback.m3u8   flag: true      (decode is identity on the secret)

in : .../v1/SECRET%2FBLOB123/track.m3u8
path: /v1/SECRET%2FBLOB123/track.m3u8        (%2F NOT decoded — segment structure preserved)
out: .../v1/<redacted>/track.m3u8            flag: true

in : .../v1/9f3c%2531b7e2a4d/track.aac        (double-encoded)
out: .../v1/<redacted>/track.aac             flag: true

in : .../v1/Zj8vYw%3D%3D/track.aac
path: /v1/Zj8vYw==/track.aac                 (8 chars after decode — under the 12 floor)
out: .../v1/Zj8vYw==/track.aac               flag: false
```

Reading of these results:

- **A ≥12-character credential of unreserved characters is encoded
  identically or not at all**, so the classifier sees the same string whether
  or not decoding happened. All credentials this app actually holds (bearer
  token, gupId, SXMAKTOKEN — per the type's own docs) are in this class.
- `%2F` is **not** decoded by `URL.path`, so an encoded slash cannot split a
  credential into two under-floor segments. The one structural hole encoding
  could have opened does not exist.
- Divergence only appears when escapes are involved, and then it tips toward
  *more* redaction: escape sequences with uppercase hex letters (`%2F`,
  `%3D`) contain an uppercase ASCII character and trip `isOpaque` clause 1 (RedactingURL.swift:225), e.g. `abcdef%2Fghijkl` is redacted as
  over-redaction, safe direction.
- The one case that *escapes* (`Zj8vYw%3D%3D`, 8 chars after decode) is an
  **F1-4** case — a sub-floor secret — not an F1-1 defect; encoding merely
  changes which side of the already-accepted floor it sits on.

**The real cross-platform sensitivities** (trailing-slash retention,
whitespace tolerance in `URL(string:)`) were already identified in the fix doc
§6 and are routed around: `pathShapeSurvivesRedaction`
(RedactingURLTests.swift:556) asserts against `redactedPath` directly for
exactly this reason, as does the pre-existing `unparseableStringYieldsNothing`.

**Verdict: REFUTED** as a determinism/correctness defect on the shipping
platform. On every realistic credential shape the classifier input is
platform-independent; on every probed escape-bearing shape the Linux behaviour
redacts or falls into the accepted F1-4 trade. Residual: because nothing has
compiled on macOS, byte-level parity of the 263-test suite on Darwin remains
assumed, not observed — but no committed test asserts the paths where
Foundation is known to differ (they were written to route around them), so
there is no identified mechanism by which the suite goes red on macOS.

A cosmetic, non-security consequence worth knowing: `render` emits the
**decoded** path, so `description` is not guaranteed byte-identical to
`absoluteString` for URLs containing escapes (case 3 above renders `==`, not
`%3D%3D`). Log-formatting only; both escaped and unescaped forms of every
probed credential are withheld when they are above the floor.

---

## F1-2 Vacuous assertions + false header — CONFIRMED CLOSED by `4ad4b4e`

**Original finding:** the file header claimed "four tests" under Reflection
when there were seven (higher counts elsewhere), and two reflection tests
lacked a non-emptiness guard.

**At `d1e945f`** the header read "covered ... by four tests" — false; the
Reflection section had grown past that. **`4ad4b4e` rewrote the header** to the
counted truth: "seven tests that inspect a real value — three that read
`dump()` output, two that read the mirror's rendered children, and two that
read the mirror's children as values — and by an eighth,
`emptinessGuardRejectsAnEmptyMirror`". Verified against the file: exactly
three dump tests, `mirrorChildrenCarryNoToken` + `mirrorChildrenCarryNoPathSecret`
(rendered children), `mirrorExposesNoURL` + `mirrorExposesNoURLForPathSecret`
(children as values), plus the eighth. Accurate.

**Vacuity guards, test by test** (line numbers at `4ad4b4e`):

| Test | Guard |
|---|---|
| `dumpRendersNoToken` :93 | `!sink.isEmpty` (:100) |
| `dumpRendersNoPathSecret` :105 | `!sink.isEmpty` + requires `<redacted>` **present** (:110,:114) |
| `dumpOfNestedValueRendersNoPathSecret` :117 | same pair (:127,:129) |
| `mirrorChildrenCarryNoToken` :132 | `mirrorVacuityReason(...) == nil` (:141) |
| `mirrorChildrenCarryNoPathSecret` :197 | inline `!rendered.isEmpty` + marker presence (:204,:206) |
| `mirrorExposesNoURL` :209 | `!description.isEmpty` + `!mirror.children.isEmpty` (:217,:219) |
| `mirrorExposesNoURLForPathSecret` :226 | same (:230,:232) |

`emptinessGuardRejectsAnEmptyMirror` (:147) is non-trivial: it first proves
the premise (`emptyMirror.children.isEmpty`, `emptyRendering.isEmpty`), then
proves the absent-secret assertion *would* pass vacuously
(`!emptyRendering.contains(Self.secret)` at :165), then proves the guard
rejects it (:167) — and additionally proves the guard discriminates (accepts
the real mirror, :173; branch 2 live via a forced empty rendering, :178;
branch 3 live via an `UnredactedMirrorValue` that puts the raw `URL` in the
mirror, :186-194).

**Empirical corroboration:** suite count went 262 → 263 at `4ad4b4e`, exactly
one new test, all passing; and the revert-experiment above shows the guards
bite on real failures rather than passing on nothing (e.g.
`dumpRendersNoPathSecret` fails at *both* :111 and :114 under the revert).

**Verdict: CONFIRMED** as raised, **and CONFIRMED CLOSED** by `4ad4b4e` on
Linux.

---

## F1-3 `displayTarget` bypass — CONFIRMED as bypass; severity LOW; accept with follow-up

`Sources/SiriusXMProtocol/Endpoints.swift:35`:

```swift
public var displayTarget: String { "\(host.name)\(path)" }
```

Raw concatenation of path, no `RedactingURL` involvement. The bypass is real
as a *code path*: `displayTarget` never consults the redaction rule.

**Exploitability today: none.** Evidence:

- Every endpoint path is a compile-time constant with no credential:
  `/profile/v4/profiles/me`, `/subscription/v1/subscriptions`,
  `/session/v1/sessions/refresh`, `/player`, and
  `module(_:trial:)`'s `/rest/v2/experience/modules/\(operation.name)` where
  `operation.name` is one of two fixed strings (Endpoints.swift:51-52).
  No credential can enter any of them.
- `displayTarget` **excludes the query by construction**, and a pinned test
  (`displayTargetExcludesTheQuery`, Tests/SiriusXMProtocolTests/EndpointTests.swift:66)
  keeps it that way — so the component where SiriusXM actually puts
  credentials today can never pass through this accessor at all.
- `grep -n displayTarget Sources`: one definition, **zero production call
  sites**. The only user is a test composing a log-line shape.

**The latent trap is real:** `SiriusXMEndpoint.init(host:path:query:)` is
public, and a future endpoint with a server-supplied or credential-bearing
path would render in full through `displayTarget` into a log line — exactly
the class of bug F1 exists to close, re-opened one accessor over. The type's
own docs frame `redactedURL()` as the safe route to an address; `displayTarget`
is the wooden door next to the vault.

**Severity: LOW** (latent, no current exploit path, query excluded).
**Disposition: ACCEPT for this merge**, with a non-blocking follow-up:
derive `displayTarget` from `redactedURL()` (or run the stored `path` through
`RedactingURL.redactedPath`), and pin it with a test whose path constant
contains a sentinel. That removes the trap instead of documenting around it.

---

## F1-4 Sub-12-char / word-shaped credentials — trade ACCEPTED

**The gap, stated honestly:** RedactingURL.swift:196-227 — a core under
`minimumOpaqueLength = 12` (:51) is structural; a ≥12 core survives if it has
no uppercase ASCII, is not all-hex, and contains a ≥4 run of lowercase letters
(:225-227). So `siriusxmsubscriberid` (19 lowercase letters, run of 19) —
the skeleton's example — renders in full, as does any sub-12 secret.

**Reasoning for ACCEPT:**

1. **The primary credential carrier is not the path.** Every SiriusXM
   credential the app holds travels in the query (`?consumer=k2&token=…&gupId=…`)
   or in headers — and the query is redacted wholesale regardless of content,
   not classified. The path rule is the braces to that belt; it exists for a
   *hypothetical* signed-media gateway that moves the credential into the
   path, and such gateways use long opaque blobs (signed-URL tokens are
   uniformly ≫12 chars of base64/hex), which the rule catches.
2. **Tightening is not free; it is not even clearly available.** Lowering the
   floor below 12 only catches 8-11-char secrets while making the rule judge
   more real route words; catching *word-shaped* ≥12 secrets requires
   deleting clause 3 (:227), which redacts `authentication` (14),
   `subscriptions` (13), `segment-000012` (13) — the over-redaction the
   `ordinaryPathsRenderInFull` contract (RedactingURLTests.swift:694) forbids.
   There is no cheap variant that catches the cited examples without breaking
   the shipped paths' rendering.
3. **Failure direction is loud.** A future verifier who disagrees can flip
   `minimumOpaqueLength` and read the test failures.
4. The trade is documented at the point of decision (type docs
   RedactingURL.swift:216-222 and fix doc §2 "The trade, named"), not buried.

**Verdict: ACCEPT the trade.** Not a merge blocker. If a future phase
onboards an endpoint with a short or word-shaped path secret, that endpoint —
not this rule — is the fix site: such paths must not be built through
`RedactingURL` rendering expectations at all.

---

## Adversarial verification beyond the four findings

### Over-redaction

`ordinaryPathsRenderInFull` (:694) pins **eleven** real addresses — all six
endpoint shapes plus CDN media/artwork (`master.m3u8`, `segment-000012.aac`,
`segment.part00001.ts`, `channel-17.jpg`, `channel-17-1280x1280.jpg`) — to
byte-identical rendering and `!carriesSensitiveComponents`. The classifier
boundary is asserted directly (`classificationRuleIsStated` :653,
`classificationFloorIsExact` :672, `onlyKnownExtensionsArePeeled` :683),
including `authentication` (14, survives on clause 1), `bitrate-128000`, and
the two-dot `segment.part00001.ts` (last-dot peeling only,
RedactingURL.swift:177). Under the revert-experiment these tests stayed
green, proving they are false-positive guards rather than vacuous. No real
route word is eaten. Edge behaviour verified by probe: escapes like `%2F`
(redacted, safe direction) and non-ASCII (runs broken, tends opaque — safe
direction, documented).

### Is `mirrorVacuityReason` strong enough?

`mirrorVacuityReason` (:770) is a **vacuity guard, not a leak detector**, and
it is sufficient in that role but must not be mistaken for more:

- **A mirror that renders the marker and still leaks would satisfy the guard
  in isolation** — e.g. children `["rendered": description, "leaked": <raw URL>]`
  contains both `<redacted>` and the secret. The guard returns `nil` on it.
- **That is not exploitable in the current suite**, because the guard never
  stands alone: every user pairs it with `!rendered.contains(Self.<secret>)`
  (:143, :205), which the leaking mirror fails. The leak assertion is the
  detector; the guard only proves the detector was looking at real redacted
  output.
- Branch 3's exercise is genuine: the `UnredactedMirrorValue` case (:186-194)
  is a mirror that *has* children carrying the raw `URL`; it fails branch 3
  (no marker in the rendering) and would *also* fail the secret-absence
  assertion — both proven by positive control (`leakyRendering.contains(Self.secret)` :192 is asserted).

Sufficient for purpose. One latent gap, stated for the record: the guard
checks absence of **the sentinel under test**, so a fixture carrying two
different secrets and asserting only one would still pass while leaking the
other. Not the case for any current fixture (each has one credential); worth a
comment if a two-secret reflection fixture is ever added.

### New defects introduced by `4ad4b4e`

**None found.** The change is tests-only (169 insertions, 18 deletions, one
file). Read in full. Specifically checked:

- Count assertions `components(separatedBy: RedactingURL.redaction).count - 1 == 2`
  (interpolation :257, dictionary :332) count occurrences correctly; no
  off-by-one.
- `emptinessGuardRejectsAnEmptyMirror` has no platform-assuming assertion
  brittle on Darwin — its raw-URL positive control (:190-192) relies only on
  `String(describing: URL)` containing the query, which holds on both
  Foundations.
- Suite green on Linux before and after revert-restore cycle: 263 → (42
  issues under revert) → 263. Tree byte-identical after restore (`git status`
  clean).
- Minor maintainability note, not a defect: `mirrorChildrenCarryNoPathSecret`
  (:200-202) re-implements `mirrorRendering` inline instead of calling it,
  against the drift rationale the new foot-of-file comment itself states.
  Harmless today; consolidate on next touch.

### Surrounding leak paths (spot-checked, in scope of the security claim)

- `RequestFingerprint` renders the URL through `RedactingURL`
  (Sources/SiriusXMNet/RequestFingerprint.swift:21) — inherits path redaction;
  the fix doc's claim verified.
- `RedactingURL` has no `Codable`, no `RawRepresentable`, no public
  string-parse-out init; `resolvedURL` and `path` (RedactingURL.swift:70, :79)
  are the only raw accessors, both documented as leak sites, and `path` has no
  caller outside tests.
- `SiriusXMProbe` prints only `report.line` and metadata; no raw `URL`
  interpolation of credential-bearing addresses (`ProbeMain.swift` reviewed).

---

## Checklist

- [x] Read RedactingURL.swift in full — :1-269
- [x] Read RedactingURLTests.swift in full (:1-781) incl. deliberate-exception
  sections and the guard at the foot
- [x] Read Endpoints.swift `displayTarget` (Endpoints.swift:35) + all endpoints
- [x] Attack: description/debugDescription/interpolation/Mirror/dump/nesting/
  Optional/Any/dictionary set-membership — all closed by tests that pair a
  presence (marker) assertion with the absence assertion; reflection closed
  by `CustomReflectable` carrying no `URL` at all (:263-268)
- [x] Over-redaction: 11 real addresses render byte-identical; boundary
  pinned; result: no legit path touched
- [x] `swift build` + `swift test` on Linux: clean build, 263/263 pass
- [x] Revert-experiment: **CONFIRMED** — 18 tests fail, exactly 42 issues
- [x] Final verdict on sub-12/word-shaped gap: **ACCEPT** (F1-4)

## Workspace hygiene

All scratch (`f1_probe.swift`, `main.swift`, `f1_render`, `f1_r2`,
`RedactingURL.fixed.swift`) lived and ran in `/tmp/agent-shared/qa-scratch/`,
**outside the repo**. Verified by `git status` (clean apart from this file)
and `git ls-files` before the final push: **no QA scratch file is in the
committed tree.** Scratch dir and clone are under `/tmp/agent-shared/`, which
is the sanctioned scratch volume. The only committed content on this branch is
this document.

## Verdict

**ACCEPT.** The fix correctly closes path-embedded credential rendering on
every reachable string path on Linux; the tests are non-vacuous and proven to
bite (42 issues under revert); the header falsehood is fixed; the residual
gaps (F1-3 latent trap, F1-4 stated trade) are real, small, and correctly
documented rather than hidden. Recommend merge of
`fix/f1-path-redaction` + `test/f1-nonvacuous-tests`, with the
`displayTarget`-through-`redactedURL` hardening filed as a non-blocking
follow-up. macOS CI remains a standing gap for the whole project — one
`swift test` run on kane after restage closes the last assumed-not-observed
item — but nothing found here gives a specific reason to expect a Darwin
failure.
