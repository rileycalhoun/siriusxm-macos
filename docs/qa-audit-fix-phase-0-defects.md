# QA adversarial audit — `fix/phase-0-defects`

Audited HEAD: `8c7560ac89889d9b0c00e9c9328920ec3fd2349e`.
Base: `89aff9b1317d6c51c1562112eacc16e2dfd60798` (`origin/phase-0-scaffolding`).
Read-only audit. Nothing executed; the Mac mini was unreachable and there is no
shell in this context. Every claim below is marked **[reasoning]** (derived from
reading code) or **[verified]** (cross-checked between at least two artifacts:
commit diff, full file at branch HEAD, and where applicable the fix-author doc's
own claims). "Verified" here means verified by reading, not by running.

## What was read

- All five commit diffs with `full_patch`: `fa6ffba`, `ba85296`, `04ca84d`,
  `ca186a2`, `8c7560a`.
- Full files at branch HEAD:
  - `Sources/SiriusXMNet/RetryPolicy.swift`
  - `Sources/SiriusXMNet/RetryingTransport.swift`
  - `Sources/SiriusXMNet/HTTPTransport.swift`
  - `Sources/SiriusXMNet/HTTPRequest.swift` (header redaction, request spec)
  - `Sources/SiriusXMNet/HTTPResponse.swift` (`TransportError`, payload,
    `Retry-After` parsing)
  - `Sources/SiriusXMNet/RequestFingerprint.swift`
  - `Sources/SiriusXMNet/Sleeper.swift`
  - `Sources/SiriusXMNet/BoundedSessionRefresher.swift` (other consumer of the
    retry vocabulary)
  - `Sources/SiriusXMCore/RedactingURL.swift`
  - `Sources/SiriusXMProtocol/Endpoints.swift`, `ModuleAPI.swift` (only module
    that builds URLs / consumes the net layer below the probe)
  - `Tests/SiriusXMNetTests/RetryPolicyTests.swift`,
    `RetryingTransportTests.swift`, `TestDoubles.swift`
  - `Tests/SiriusXMCoreTests/RedactingURLTests.swift`
  - `Package.swift`
- `docs/phase-0-scaffolding-fixes.md` (the fix author's own claims; cross-checked
  against the code).

Method note: GitHub code search does not index this branch, so "no other switch
site" claims were established by reading every file in `Sources/SiriusXMNet` and
`Sources/SiriusXMProtocol` and the three touched test files, not by grep.

## Verdict

**No BLOCKER findings. No HIGH findings.** All four fixes close the defects they
claim to close. Findings: 1 MEDIUM, 9 LOW (several LOWs are pre-existing
conditions this branch neither caused nor worsened, recorded so they are not
lost). The branch is mergeable on the evidence available, subject to the one
caveat that nothing — neither the fixes nor this audit — has been executed on
macOS.

## Per-fix verdicts

### Fix 1 — `RetryPolicy` ordering — SOUND

Input domain walked exhaustively against the new code at
`Sources/SiriusXMNet/RetryPolicy.swift:105-122` and `:131-142`:

- status path: 2xx → `.succeeded` at any attempt; 401/403 → `.permanentStatus`
  at any attempt; 429/5xx → `.retry` iff `attempt < maximumAuthAttempts`, else
  `.budgetExhausted(attempts:)`; all other codes (1xx, 3xx, 4xx other than
  401/403/429, 600+, 0, negative) → `.permanentStatus`. No wrong decision found.
- transport path: cancellation first (`.cancelled`), then recoverability
  (`.unrecoverableTransport`), then the budget (`.budgetExhausted`), then
  `.retry`. No case mislabels another.
- No path offers an unbounded retry. `RetryingTransport.send`
  (`RetryingTransport.swift:68-108`) increments `attempt` once per send and only
  loops on `.retry`, which both `decide` overloads stop emitting once
  `attempt >= maximumAuthAttempts`. Worst case with the default policy is
  exactly 3 sends and 2 sleeps — confirmed by
  `budgetIsExactlyThree` (`RetryingTransportTests.swift`, asserts
  `sendCount == 3`, `attempts == 3`).
- `Retry-After` is honoured and clamped to `maximumRetryAfter` (60 s) at
  `RetryPolicy.swift:89-93`; computed backoff is clamped to `maximumDelay`
  (8 s) at `:80-85`. No budget exceeds the account-safety bound. Nothing new
  endangers the subscriber's account.
- Edge inputs: `attempt <= 0` is unreachable from `RetryingTransport` (loop
  starts at 1) but is not harmful if passed directly (`0 < 3`, so a 429 would
  retry with a `.zero`-adjacent wait; bounded, harmless). Negative
  `retryAfterSeconds` is finding F4 below.

What would falsify "sound": a caller outside `RetryingTransport` constructing
its own loop that re-enters `decide` without incrementing `attempt`, or a
`RetryPolicy` constructed with `maximumAuthAttempts` set to `Int.max` — the
field is a mutable public `var` (`RetryPolicy.swift:45`), so the bound is a
default, not an invariant (pre-existing; informational only).

### Fix 2 — `RedactingURL` reflection redaction — SOUND within its contract

`customMirror` (`RedactingURL.swift:121-126`) carries exactly two children, a
`String` (`description`, already proven safe) and a `Bool`. No `URL` value is
reachable through `Mirror` or `dump()` on a `RedactingURL` itself.

Leak-path enumeration:

- `dump()` / `Mirror(reflecting:)` on `RedactingURL` directly: closed —
  `CustomReflectable` is consulted by both. **[reasoning]** — this is documented
  Swift reflection behaviour; the doc's captured pre-fix `dump()` output
  (Linux) confirms the leak existed and the shape of the fix.
- Mirror/`String(describing:)` on a struct that *contains* a `RedactingURL`:
  the child's own `CustomReflectable`/`CustomStringConvertible` is honoured at
  each recursion level, so containment re-enters the redacted paths. Covered by
  `nestingInAPlainStructIsRedacted` and `mirrorChildrenCarryNoToken`.
  **[reasoning]**
- `Optional`, `Any`, collections, dictionary keys: all render through the
  element's description/reflection, which are the closed paths. Covered by the
  pre-existing erased-type and collection tests.
- `Hashable`/`Equatable`: synthesized over the private `url`, but hash values
  are not reversible and equality produces no text. Not a leak path.
  **[reasoning]**
- Error boxing: no error type in the audited sources stores a `RedactingURL`;
  `TransportPolicyError.unrecoverableTransport` stores a `TransportError`
  (slug-only description, `HTTPResponse.swift`) and a `RequestFingerprint`
  (hex slug over an already-redacted rendering, `RequestFingerprint.swift`).
  Covered by `unrecoverableTransportRendersSafely` and
  `policyFailureRendersSafely`.
- `resolvedURL` (`RedactingURL.swift:55`): by-design escape hatch, honestly
  documented. Its one use in the audited graph,
  `HTTPTransport.swift` `send()` (`URLRequest(url: request.url.resolvedURL)`),
  hands it straight to a request. `URLError`s are caught and reduced to slugs
  before storage, so the URL does not ride out through a thrown error.
- Hardcoded tokens: none. Every sentinel (`SECRETTOKENVALUE`, `SECRETPASSWORD`,
  `SECRETFRAGMENT`, `DIFFERENTTOKEN`) is synthetic on `.invalid` hosts.
  **[verified]** in all three touched test files.
- Remaining hole of this type: secrets embedded in the URL **path** still
  render. That is F1 below.

### Fix 3 — lock-guarded `URLSession` — SOUND

- Every read and write of `madeSession` occurs inside `sessionLock`
  (`HTTPTransport.swift:44-51`). Check, construct, and assign are one critical
  section, so there is no TOCTOU and exactly one session can ever exist.
- Deadlock by re-entry: `URLSession(configuration:delegate:delegateQueue:)` does
  not synchronously invoke its delegate during initialisation, and nothing
  inside the critical section calls back into `session`. `NSLock` is
  non-recursive, but no re-entry path exists. **[reasoning]**
- `configuration` is captured (copied by `URLSession`) at construction and is
  never mutated after `init`, so there is no post-construction mutation race.
- The one `URLSessionTaskDelegate` method (redirect refusal,
  `HTTPTransport.swift:~99-106`) is stateless and touches no shared state, so
  it has no locking assumptions to violate.
- The compile-error justification for the shape (a subclass's stored properties
  must be initialised before `super.init()`, and a `let` cannot be assigned
  afterwards) is correct Swift semantics **[reasoning]**; the two quoted
  diagnostics match real compiler messages. Not executable-verified here.
- No new `@unchecked Sendable` was added; the conformance predates the branch
  and the fix removes the data race that made it a lie. The remaining
  `@unchecked` is justified by the lock.

What would falsify "sound": Foundation calling a delegate method synchronously
from `URLSession.init` (not observed behaviour on either platform), or a future
edit that reads `madeSession` outside the lock.

### Fix 4 — `policyFailure` reason mapping — SOUND, with one latent defect (F2)

`RetryDecision.StopReason` has five cases. Reachability into the `switch` at
`RetryingTransport.swift:115-127`:

- `.cancelled` — filtered out earlier at `send()` lines ~84-85 (`case
  .stop(reason: .cancelled)` throws directly), but also mapped correctly inside
  `policyFailure`. Double-covered, correct.
- `.unrecoverableTransport` — mapped to the new
  `TransportPolicyError.unrecoverableTransport`. Correct, and the reason is
  preserved through.
- `.succeeded` / `.permanentStatus` — cannot reach `policyFailure`: the
  status-path switch handles both at lines ~99-103, and
  `decide(transportError:)` never emits either. The `default:` arm only ever
  receives `.budgetExhausted`. **[reasoning]**, grounded in call-site analysis,
  not execution.
- The exhaustive `switch` over `TransportPolicyError` in `description`
  (`RetryingTransport.swift:18-27`) handles all three cases. No other switch
  over `TransportPolicyError` exists in the audited sources — `BoundedSessionRefresher`
  works in `CredentialError` vocabulary, and `SiriusXMProtocol` never switches
  on it. Tests use `guard case` bindings, not exhaustive switches. Nothing is
  silently non-exhaustive elsewhere. **[verified]** by reading every file in
  `Sources/SiriusXMNet` and `Sources/SiriusXMProtocol`; see the method note.

## Findings

### F1 — MEDIUM (security, latent): path-embedded secrets are not redacted

- `Sources/SiriusXMCore/RedactingURL.swift:98` — `render` emits `url.path`
  verbatim; `carriesSensitiveComponents` at `:74` checks query/fragment/user
  /password but not the path.
- Trigger: `RedactingURL(string: "https://cdn.example/stream/SECRETTOKENVALUE/list.m3u8")`
  prints the token through every closed path — `description`,
  `debugDescription`, `customMirror`'s `rendered` child, interpolation,
  collection rendering. The mirror fix does not help: `rendered` *is* the leak.
- This is the documented contract ("renders the scheme, host, and path"), and
  today every token this app handles lives in the query string
  (`SiriusXMEndpoints` builds only query-based URLs; the media-token case is
  `?token=` per the type's own doc). So it is a caller-misuse hole, not an
  active leak. But this type is the app's single defence against tokens
  reaching logs, and CDN-style stream URLs with tokens in path segments are a
  real shape this codebase may meet in a later phase. Then the first log line
  prints it and nothing detects it — `carriesSensitiveComponents` answers
  `false`.
- Fix: at minimum, document the path exclusion in `carriesSensitiveComponents`
  and add a debug assertion point. Better: treat a path that could not be
  classified as structural (e.g. known extensions / segments) as sensitive in
  media contexts, or add a `RedactingURL` initialiser variant that redacts a
  designated path segment range for stream URLs.

### F2 — LOW (latent): `default:` arm in `policyFailure` will mislabel future stop reasons

- `Sources/SiriusXMNet/RetryingTransport.swift:125-126` — `default: return
  .budgetExhausted(attempts:fingerprint:)`. Today reachable only by
  `.budgetExhausted` (see Fix 4 analysis), which is exactly the defect class
  this commit fixed: a future `StopReason` case (say `.serverDirected`) would
  compile silently and be reported as a spent budget — the same lie, re-opened
  by a door this commit left unlocked.
- Fix: switch exhaustively — `case .budgetExhausted: return .budgetExhausted(...)`,
  and for the two logically-unreachable cases (`.succeeded`,
  `.permanentStatus`) an explicit arm with `preconditionFailure` or a mapped
  budget error *plus* a comment, so a new case produces a compile error, not a
  mislabel.

### F3 — LOW (test): `mirrorExposesNoURL` can pass vacuously

- `Tests/SiriusXMCoreTests/RedactingURLTests.swift:~74-81` — the loop has no
  assertion that `mirror.children` is non-empty; a `customMirror` returning
  `children: [:]` passes. The sibling test `dumpRendersNoToken` has the
  non-empty guard and this one should have it too.
- Fix: `#expect(mirror.children.count == 2)` (or non-empty) before the loop.

### F4 — LOW: negative `retryAfterSeconds` is not floored in `RetryPolicy.delay`

- `Sources/SiriusXMNet/RetryPolicy.swift:89-93` — only the upper bound is
  clamped (`min(requested, maximumRetryAfter)`). A negative input yields a
  negative `retry(after:)`.
- In-repo this is unreachable: `HTTPResponsePayload.retryAfterSeconds`
  (`HTTPResponse.swift`, the `seconds >= 0` guard and the date-math floor)
  never returns a negative. And a negative `Duration` is harmless downstream —
  `DispatchSleeper` returns immediately when `nanoseconds <= 0`
  (`Sleeper.swift`). So: no hang, no hot loop beyond the 3-attempt bound, no
  account risk. Latent for direct public callers of the policy only.
- Fix: `Duration.seconds(max(0, min(requested.seconds, maximumRetryAfter.seconds)))`.

### F5 — LOW (pre-existing): `URLSessionTransport` retain cycle with no invalidation path

- `Sources/SiriusXMNet/HTTPTransport.swift:41-51` — `self → madeSession`, and
  `URLSession` retains its `delegate` (`self`) until invalidated. The class has
  no `deinit` (the cycle prevents it) and no `invalidateAndCancel` entry point.
  Exactly one session can exist (the fix guarantees that), so this is a bounded,
  process-lifetime hold rather than a growth leak — but it is worth recording:
  an explicit `close()` that calls `invalidateAndCancel()` and nils
  `madeSession` under the lock is the clean exit. Present identically under
  `lazy`; the fix neither caused nor worsened it.

### F6 — LOW (pre-existing): `init` mutates the caller's `URLSessionConfiguration` in place

- `Sources/SiriusXMNet/HTTPTransport.swift:53-64` — the passed-in configuration
  object (a reference type) is mutated (cookies/cache/credentials/timeouts
  stripped) before being stored. A caller sharing that configuration instance
  elsewhere is silently affected. The default path (`.ephemeral`, fresh per
  call) is unaffected.
- Fix: copy at entry, `guard let configuration = configuration.copy() as?
  URLSessionConfiguration`, then harden the copy.

### F7 — LOW (cosmetic): stale comment — "These four tests" heads a 10-test section

- `Tests/SiriusXMNetTests/RetryPolicyTests.swift:~84-88` — the MARK block
  comment says "These four tests pin that ordering down"; the section contains
  ten tests. Cosmetic; erodes trust in the surrounding claims of rigor.

### F8 — LOW (cosmetic): doc typo in worktree path

- `docs/phase-0-scaffolding-fixes.md` — the worktree is `sxm-fixes` in the body
  and `smx-fixes` in the Cleanup section. The claimed removal is not in doubt;
  the name is transposed in one place.

### F9 — LOW (pre-existing): cancellation mid-backoff escapes as a raw `CancellationError`

- `Sources/SiriusXMNet/RetryingTransport.swift:82` and `:97` — if the task is
  cancelled while the sleeper is waiting, `sleep(for:)` throws
  `CancellationError`, which is not a `TransportError`, so it propagates out of
  `send()` unwrapped rather than as `TransportPolicyError.cancelled`. Callers
  get a different type depending on *when* cancellation landed. Semantically
  harmless (both are stops, never retried), inconsistent in presentation.
  Not caused by this branch; recorded because Fix 4's theme is exactly
  reason-fidelity.

### F10 — LOW (pre-existing, scale): the attempt ledger grows unboundedly

- `Sources/SiriusXMNet/RetryingTransport.swift:46` and `:130-134` —
  `attemptsByFingerprint` gains one permanent entry per distinct request
  fingerprint and is never pruned or reset on success. A long-lived instance
  that sends many distinct stream URLs (new token per track → new URL → but
  the token is excluded from the fingerprint, so identical tracks share one
  entry; *distinct tracks* are distinct entries) accumulates one ~24-byte-keyed
  entry per track. Slow growth, bounded by listening history; a `reset` on
  success or an eviction bound would close it. Not introduced by this branch.

## Explicit negatives — checked, nothing found

- **Unbounded retry anywhere**: none. All retry emission is gated on
  `attempt < maximumAuthAttempts`; loops increment once per send.
- **Account-safety regression**: none. Default budget unchanged at 3; 401/403
  still never retried; `Retry-After` still honoured and capped.
- **New `@unchecked Sendable`**: none added by this branch (`URLSessionTransport`,
  `RetryingTransport`, test doubles all pre-date it).
- **Weakened assertion / skipped or disabled test**: none. All three touched
  test files contain no `.disabled(`, `withKnownIssue`, or `.enabled(if:)`.
- **Widened accessibility**: only `customMirror` is `public`, which the protocol
  requires.
- **Third-party dependency or protection circumvention**: none. `Package.swift`
  is untouched on this branch; still zero dependencies, Swift 6 mode,
  `.macOS(.v14)`. `NSLock` (not `Synchronization.Mutex`) is the correct choice
  at that deployment target.
- **Tautological tests / tests asserting their own implementation**: none found
  beyond F3's vacuity nit. The fingerprint assertions compute
  `RequestFingerprint.of(Self.request)` — the real production function, not a
  reimplementation cut into the assertion. The 6 of 19 new tests that are green
  against the pre-fix code are disclosed in the fix doc itself, and the
  doc's table of them matches the code I read: they pin behaviour the
  reordering must not change (500-at-attempt-3, 429-before-budget, 429-at-limit,
  timeout-at-limit, cancellation-at-limit, timeout-driven budget exhaustion).
  That category is legitimate regression-guard work, honestly labelled, and the
  doc's count (13 red of 19) is consistent with the diffs.
- **Other tests whose names promise more than the body checks**:
  `budgetExhaustedMeansOnlyTheBoundWasReached` asserts the *exact* error
  including the fingerprint; the two render-safety tests assert absence of the
  sentinel, absence of `https://`, and presence of the slug. No over-promising
  names found beyond the F3/F7 nits.
- **Linux-only Foundation behaviour in tests**: the three reflection tests are
  platform-independent by construction — with `CustomReflectable` in place, the
  mirror children are a `String` and a `Bool`, and the test assertions never
  touch the platform's `URL` internals (the pre-fix capture in the doc descends
  into `FoundationEssentials.URLParseInfo`, but that is the *before* state the
  fix removes). `dump(to:)` uses a generic `TextOutputStream` sink, portable.
  Claim: these tests should pass identically on Darwin **[reasoning]**, for the
  same reason the fix is platform-independent. Not executed — the doc itself
  correctly flags that nothing on this branch is macOS-verified, and this audit
  cannot close that gap either.

## Bottom line

Four fixes, all sound, zero blockers. Merge-gate checklist is empty apart from
two conditions: (1) run the suite once on macOS before calling this
platform-verified — F1's fix and the reflection tests both lean on reasoning
about Darwin Foundation, not evidence; (2) decide whether F2's `default:` arm is
fixed here or in the next phase, since it re-opens the exact defect class of
commit 4 by one keyword.
