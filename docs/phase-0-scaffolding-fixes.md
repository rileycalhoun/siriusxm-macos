# phase-0-scaffolding: four confirmed defects, fixed

Four defects reported against `origin/phase-0-scaffolding` (`89aff9b`), fixed on
one branch with tests that were shown to fail before the fix and pass after it.

**Nothing in this work was verified on macOS.** The Mac mini build machine was
unreachable for this task. Every build, test, and red-then-green result below was
produced on Linux (`x86_64-unknown-linux-gnu`, Swift 6.1.3). See
[Not verified on macOS](#not-verified-on-macos).

## Where this was done

The candidate agent workspace `/projects/siriusxm-macos/siriusxm-macos` holds only
AiderDesk metadata — it has no `.git`. The writable checkout is the repository root
one level up, `/projects/siriusxm-macos`.

That checkout was **not** used for the work, because it carried uncommitted
changes that are not mine. See [Shared-checkout hazard](#shared-checkout-hazard).

Work was done in a linked git worktree branched from `origin/phase-0-scaffolding`:

- worktree: `/tmp/agent-shared/sxm-fixes`
- branch: `fix/phase-0-defects`
- the scratch worktree was removed after the push

Push credentials work from this container through the `github-sxm-rileycalhoun`
SSH alias, which the existing checkout already had configured as `origin`. `ssh
undertaker` was not needed. `master` was not branched from and not modified.

## Branch and commits

Base: `89aff9b1317d6c51c1562112eacc16e2dfd60798` (`origin/phase-0-scaffolding`)

| SHA | Subject |
| --- | --- |
| `fa6ffba76fbe7e58178d4e7aa2488c4356d993a5` | fix(net): classify status before consulting the retry budget |
| `ba852962668a3b89930fe60a3f6f7fc02ffa662c` | fix(core): redact RedactingURL under reflection |
| `04ca84da5149fd607c9fa8f660e72591de5e308e` | fix(net): build the URLSession once under a lock |
| `ca186a226395846c3e3cf9027a6a0e6bc1e640f4` | fix(net): report an unrecoverable transport failure as itself |

## What each fix does

### 1. `RetryPolicy` read the budget before the response (BLOCKER)

`decide(statusCode:attempt:retryAfterSeconds:)` checked `attempt >=
maximumAuthAttempts` before the `switch` on the status. With the default of three
attempts, the third attempt returned `budgetExhausted` without reading the status:
a `200` was discarded and thrown, and a `401` was misreported as the service being
busy. `decide(transportError:attempt:)` had the same ordering, so a TLS failure on
the last attempt was also reported as a spent budget.

The status is now read first, and the budget is consulted only inside the branches
that would actually offer another attempt. 2xx always yields `.succeeded`; 401/403
always yields `.permanentStatus`; 429 and 5xx yield `.budgetExhausted` only when the
budget is genuinely spent and `.retry` otherwise. In the transport path the order is
now cancellation, then recoverability, then budget. The doc comment stating that a
401 is a stop is unchanged and still true.

### 2. `RedactingURL` leaked the token through reflection (BLOCKER, security)

The type conformed to `CustomStringConvertible` and `CustomDebugStringConvertible`
but not `CustomReflectable`, so `dump()` and `Mirror(reflecting:)` — which ignore
both description protocols and walk stored properties — printed the private
`private let url: URL` in full, query string and token included.

`RedactingURL` now conforms to `CustomReflectable`. Its `customMirror` exposes no
`URL` value at all: only the already-redacted `rendered` string and the
`carriesSensitiveComponents` flag. The type doc comment previously implied its list
of closed leak paths was complete, which was false; it now says that the rendering
list covers description paths and that reflection is closed separately, by a
different conformance for a different reason.

The captured `dump()` output before the fix, showing that `dump()` renders the
summary line through `description` and then recurses into the mirror anyway:

```
▿ https://live.example.invalid/stream/track.m3u8?<redacted>
  ▿ url: https://live.example.invalid/stream/track.m3u8?token=SECRETTOKENVALUE&gupId=SECRETTOKENVALUE
    ▿ _parseInfo: Optional(FoundationEssentials.URLParseInfo)
      ▿ some: FoundationEssentials.URLParseInfo #0
        - urlString: "https://live.example.invalid/stream/track.m3u8?token=SECRETTOKENVALUE&gupId=SECRETTOKENVALUE"
```

The redacted first line is the description path working. Everything under it is the
reflection leak, and it leaks the token twice.

### 3. `URLSessionTransport` raced on a `lazy` session (HIGH, data race)

`lazy` is not thread-safe, so two concurrent `send()` calls could both run the
initialiser and build two `URLSession`s, each with `self` as its delegate, while the
type asserts `@unchecked Sendable`.

**Shape used: a lock-guarded accessor, not an eagerly assigned `let`.** The
preferred shape was tried first and the compiler rejected it:

```
error: immutable value 'self.session' may only be initialized once
error: property 'self.session' not initialized at super.init call
```

Swift requires a subclass's stored properties to be initialised *before*
`super.init()`, so a `let` assigned after the superclass initialiser does not
compile — the delegate must be `self`, and `self` cannot be passed before
`super.init()`. The fallback is therefore a `sessionLock`-guarded computed property
over a `madeSession` store: the lock makes first-use construction safe, and the
single assignment under it guarantees exactly one session. `lazy` is gone, and
nothing new was made `@unchecked` to silence the checker.

### 4. `RetryingTransport` misattributed stop reasons (LOW)

`policyFailure(_:attempts:fingerprint:)` mapped every non-cancellation stop reason
to `.budgetExhausted`, so an unrecoverable transport error — wrong host, TLS
failure — was reported to the caller as a spent retry budget. Both are stops, so
nothing retried incorrectly, but the reason was wrong and would mislead anyone
debugging a rate-limit incident.

`TransportPolicyError` gained `unrecoverableTransport(reason:fingerprint:)`, and
`policyFailure` maps `RetryDecision.StopReason.unrecoverableTransport` to it.
`.budgetExhausted` now means only that the bound was reached, and its doc comment
says so.

## Red-then-green evidence

Method: the four source files were reverted to `89aff9b` behaviour while the new
tests stayed in place, then the fix was restored from a saved patch. The new
`TransportPolicyError` case was deliberately left in place during the revert, so the
tests still *compile* against the old behaviour and fail on assertions rather than
on a compile error.

Result: **13 of the 19 new tests fail against the original code and pass after the
fix.**

```
$ swift test          # original behaviour, new tests present
✘ Test run with 237 tests failed after 0.044 seconds with 14 issues.
```

Failing before the fix (13 tests, 14 issues — `dump()` produced two):

| Test | Failure against original code |
| --- | --- |
| `dump() renders no token` | token present twice in captured output |
| `Mirror exposes no child carrying the token` | `url: …?token=SECRETTOKENVALUE…` |
| `Mirror exposes no URL at all, not even a partial one` | child value is a `URL` |
| `a 200 on the final attempt is a success, not a spent budget` | got `budget-exhausted(3)` |
| `a 204 on the final attempt is a success too` | got `budget-exhausted(3)` |
| `a 401 on the final attempt is still an answer, not a spent budget` | got `budget-exhausted(3)` |
| `a 403 on the final attempt is still an answer too` | got `budget-exhausted(3)` |
| `a TLS failure on the final attempt is not a spent budget` | got `budget-exhausted(3)` |
| `a 200 arriving on the last attempt is returned, not thrown away` | threw `budget-exhausted(attempts: 3)` |
| `a 401 arriving on the last attempt is returned, not thrown away` | threw `budget-exhausted(attempts: 3)` |
| `an unrecoverable transport failure is reported as itself, not as a spent budget` | got `budget-exhausted(attempts: 1)` |
| `an unreachable host is reported as itself, not as a spent budget` | got `budget-exhausted(attempts: 1)` |
| `an unrecoverable transport failure renders without a URL or a token` | rendered `budget-exhausted(…)`, no `tls-failure` |

After restoring the fix:

```
$ swift test
✔ Test run with 237 tests passed after 0.049 seconds.
```

### The 6 new tests that were green before the fix

Six of the nineteen are **regression guards, not red-then-green**, and the task
brief's claim that every new test fails against the current code does not hold for
these. They pass both before and after, by construction:

- `a 500 on the final attempt is the one case that is a spent budget`
- `a 429 before the budget is spent is still a retry`
- `a 429 on the final attempt is a spent budget`
- `a timeout on the final attempt is a spent budget`
- `cancellation still wins on the final attempt`
- `budgetExhausted still means only that the bound was reached`

This is not a gap in the fix. Required tests 5 and 6 as literally specified —
500 on attempt 3 yielding `budgetExhausted(3)`, and 429 on attempt 2 yielding
`.retry` with a server-honouring delay — specify behaviour that is *identical*
before and after the fix. Before the fix the budget check ran first and happened to
produce the right answer for those two cases; after the fix the status check runs
first and still produces it. They are worth keeping precisely because they pin the
behaviour that the reordering must not break, but they cannot be demonstrated red.

## Test count

| | Tests | Result |
| --- | --- | --- |
| Baseline, `89aff9b`, unmodified | 218 | passed |
| This branch | 237 | passed |

**237 tests, all passing, 0 skipped.** The done criteria asked for confirmation
that the count exceeds 68. It does, but the stated baseline of 68 does not match
what is actually on `origin/phase-0-scaffolding`: the unmodified branch runs 218
tests and all 218 pass. 68 appears to be stale. The number that matters is that this
branch adds 19 tests to a green 218 without breaking any of them.

Nothing was skipped, disabled, or annotated to reach green:

```
$ grep -rn "\.disabled\|withKnownIssue\|@Test(.enabled" Tests/
(no matches)
$ swift test | grep -ciE "skipped|disabled"
0
```

Every pre-existing test still passes; the 19 new tests are purely additive.

## Build and test commands

All run from the worktree on Linux with Swift 6.1.3:

```
$ swift build
Build complete! (2.19s)

$ swift build -c release
Build complete! (9.07s)

$ swift test
✔ Test run with 237 tests passed after 0.052 seconds.
```

Both builds are clean, with no new warnings. `Package.swift` was not touched, so the
target topology that module-boundary enforcement depends on is unchanged. No
third-party dependencies were added — no CryptoKit, no new packages. Still Swift 6
language mode and `.macOS(.v14)`; `NSLock` is used because `Synchronization.Mutex`
is unavailable at that deployment target.

`/usr/local/bin/xcode-sandbox-stage` and `/usr/local/bin/xcode-sandbox-restage-sxm`
were not touched.

## Not verified on macOS

Stated plainly: **no part of this work was verified on macOS.** The Mac mini is
unreachable for this task, so there is no `xcodebuild` result, no macOS `swift test`
result, and no confirmation that any of this compiles or passes on the platform the
app actually ships on.

The specific risk this leaves open is that these tests and fixes were only ever run
against Foundation for Linux. The `RedactingURL` reflection tests depend on how the
platform's `URL` type renders under reflection — and the captured `dump()` output
above shows that on Linux it descends into `FoundationEssentials.URLParseInfo`,
which is an implementation detail of the open-source Foundation. `URL` on Darwin is
a different implementation, so the reflection shape of a `URL` there will differ.
The fix does not depend on that shape — `customMirror` exposes no `URL` at all, so
it cannot leak regardless of what a `URL` is made of — but the *tests* assert
against a mirror that should contain no `URL`, and that is the safer direction: they
should pass on macOS for the same reason the fix is correct. This is an inference,
not a verified result, and it should be confirmed on the Mac mini before this is
considered platform-verified.

## Findings outside the four defects

### Shared-checkout hazard

`/projects/siriusxm-macos` was not clean when this task started. It carried
uncommitted changes touching all four defect files (`RetryPolicy.swift`,
`RedactingURL.swift`, `HTTPTransport.swift`, `RetryingTransport.swift`, modified
between 00:35 and 00:41 UTC) plus `Package.swift`, a probe refactor, and a large
move of `Tests/SiriusXMProbeTests/` into `Tests/SiriusXMProtocolTests/`.

That work belongs to AiderDesk task `3ffd3d19` ("Brainstorm native SiriusXM app
design"), which is still `IN_PROGRESS`. Its own todo list carries these same four
defects as `completed: false`. The edits to the four source files look like a
started, partial attempt at them — and incomplete: they add no tests for any of the
four defects, which is why they are uncommitted.

**I did not touch, revert, or build on any of it.** The work here is in a separate
worktree with a separate index and HEAD, so that tree is byte-for-byte as I found
it. Two open risks for whoever picks it up:

1. That task may resume and commit this tree. It will get its own partial fixes,
   not these.
2. Its test-move refactor and this branch's test additions both touch test files.
   If both land, the `Tests/SiriusXMProbeTests/` → `Tests/SiriusXMProtocolTests/`
   rename will conflict with the test files this branch edits. Worth sequencing,
   not merging blind.

### `Tests/SiriusXMProbeTests/` has no redaction source-scan

The brief asked to check whether `Tests/SiriusXMProbeTests/` contains a redaction
source-scan needing a `dump(` entry. It does not, so no entry was added.

`Tests/SiriusXMProbeTests/RedactionTests.swift` is a **behavioural** suite. It
builds `SessionMaterial`, `AccountCredential`, `HTTPCookieField`, `HTTPResult`,
`ProbeReport`, and `Redactor` in memory and asserts on `String(describing:)` and
`String(reflecting:)`. It never reads a source file. The only `FileManager` use
anywhere under `Tests/` is `FixtureLocator.swift`, which loads JSON and cookie
fixtures for the probe module, not source text.

It also never mentions `RedactingURL` — it appears zero times in that file.
`RedactingURL` lives in `SiriusXMCore`, and `RedactionTests` is in
`SiriusXMProbeTests` with `@testable import SiriusXMProbe` only. Reflection
coverage for `RedactingURL` belongs in `Tests/SiriusXMCoreTests/RedactingURLTests.swift`,
which is where it was added.

### The `Date()` check

Not repeated, per the brief. One incidental finding: `HTTPResponse.retryAfterSeconds`
reads the clock through `timeIntervalSinceNow`, which is a hidden non-injectable time
source of the same family. Out of scope here; recorded only so it is not lost.

## Cleanup

- Scratch worktree `/tmp/agent-shared/sxm-fixes` removed after the push.
- No build artifacts committed; `.build/` is already ignored.
- No bulk added; the branch adds four source edits and three test files' worth of
  cases, all text.
