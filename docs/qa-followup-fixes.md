# QA follow-up fixes

Four defects raised by the phase-0 QA pass, all in `SiriusXMNet`, fixed on
`fix/qa-followups` branched from `origin/fix/phase-0-defects`.

Scope: `RetryingTransport.swift`, `RetryPolicy.swift`, their two test files, and
one typo in a doc already committed on the base branch. Nothing else was
touched. `HTTPTransport.swift`, `RedactingURL.swift`, `Package.swift` and the
`SiriusXMProtocol` / `SiriusXMUI` / `SiriusXMPlayback` / `SiriusXMApp` modules
were left alone.

## Test counts

| | count |
| --- | --- |
| baseline, `origin/fix/phase-0-defects` | 237 passed |
| after these four fixes | 243 passed |
| net new | 6 |

Both numbers observed on Linux (Debian 12, Swift 6.1.3, x86_64), not taken from
a note. `swift build` is clean with no warnings before and after. No test was
weakened, skipped or deleted; there is no `.disabled(` and no `withKnownIssue`
anywhere in `Tests/`.

## F2 — `default:` arm in `policyFailure` mislabelled future stop reasons

**Before.** `RetryingTransport.policyFailure` ended in a catch-all:

```swift
        case .unrecoverableTransport(let transportError):
            return .unrecoverableTransport(reason: transportError, fingerprint: fingerprint)
        default:
            return .budgetExhausted(attempts: attempts, fingerprint: fingerprint)
```

Only `.budgetExhausted` reached that arm, so it read as correct. It was not
correct. A new `StopReason` case would have compiled silently and been reported
as a spent budget — the same lie `ca186a2` had just removed, re-opened by the
addition of one enum case and nobody noticing.

**After.** The switch enumerates every case. `.budgetExhausted` returns the
budget error, and the two cases that cannot reach this function hit a
`preconditionFailure` naming the invariant. As committed:

```swift
    private func policyFailure(
        _ reason: RetryDecision.StopReason,
        attempts: Int,
        fingerprint: RequestFingerprint
    ) -> TransportPolicyError {
        switch reason {
        case .cancelled:
            return .cancelled(fingerprint: fingerprint)
        case .unrecoverableTransport(let transportError):
            // A wrong host or a bad certificate is not a spent budget. Both
            // are stops, so nothing retries differently either way, but
            // reporting it as a budget failure tells whoever is debugging a
            // rate-limit incident that the service asked them to slow down,
            // when in fact no amount of waiting would ever have worked.
            return .unrecoverableTransport(reason: transportError, fingerprint: fingerprint)
        case .budgetExhausted:
            return .budgetExhausted(attempts: attempts, fingerprint: fingerprint)
        case .succeeded, .permanentStatus:
            // Unreachable, and deliberately not papered over. `send(_:)`
            // returns the payload on both of these before it ever reaches
            // this function: a 2xx is an answer the caller wants, and a
            // permanent status is an answer only the protocol layer can
            // interpret. Reporting either as a thrown `TransportPolicyError`
            // would throw away a response that already arrived.
            //
            // There is no `default:` here on purpose. A `default` is what let
            // a new `StopReason` compile silently and be mislabelled as a
            // spent budget — the exact defect that adding
            // `unrecoverableTransport` was meant to close. Enumerating every
            // case makes the next one a compile error instead.
            preconditionFailure(
                "policyFailure(reason:) reached with \(reason); succeeded and permanentStatus both return in send(_:) before it is called"
            )
        }
    }
```

### Proof that the exhaustiveness is enforced by the compiler

The proof is a compile error, not a test. A sixth `StopReason` case,
`probeSixthCase`, was added temporarily to `RetryPolicy.StopReason`, and also
given a `description` arm so that the *only* switch left incomplete was
`policyFailure`. `swift build` then failed:

```
/tmp/agent-shared/qa-followups/Sources/SiriusXMNet/RetryingTransport.swift:116:9: error: switch must be exhaustive
114 |         fingerprint: RequestFingerprint
115 |     ) -> TransportPolicyError {
116 |         switch reason {
    |         |- error: switch must be exhaustive
    |         `- note: add missing case: '.probeSixthCase'
117 |         case .cancelled:
118 |             return .cancelled(fingerprint: fingerprint)
```

Exit status 1. Line 116 is `switch reason {` in the committed file, so the
diagnostic refers to the code as it now stands.

For the contrast, the same scratch case was built against the *original*
`policyFailure` from `origin/fix/phase-0-defects`, the one that ended in
`default:`:

```
=== OLD default: + scratch sixth case ===
...
Build complete! (1.44s)
```

Exit status 0. The old code compiled without complaint and would have reported
`probeSixthCase` as `budgetExhausted`. That difference is the whole fix.

The scratch case was reverted before committing. `grep -rn "probeSixthCase\|SCRATCH PROBE" Sources/`
returns nothing; the only occurrence of the string `default:` in
`RetryingTransport.swift` is inside the comment explaining why there is none.

### Tests for F2

Two, both in `RetryingTransportTests`, and neither trips the precondition:

- **"each failure reason maps to its own error, never onto a shared fallback"**
  drives the three reasons that legitimately reach `policyFailure` — a spent
  budget, a cancellation, a TLS failure — and asserts each produces its own
  distinct `TransportPolicyError`. It also asserts the three are pairwise
  distinct, which is the assertion a collapsing `default:` fails.
- **"no status the policy calls an answer is ever thrown instead of returned"**
  is the invariant behind the two unreachable arms, pinned by observation
  rather than by triggering the trap. For every status in 100...599 it asks
  `RetryPolicy.default.decide(statusCode:attempt: 3, ...)` what the policy
  concluded, then asserts `send` matched: a verdict of `.succeeded` or
  `.permanentStatus` came back as a payload with that exact status code, and
  only a `.budgetExhausted` verdict threw. If `send` were ever changed to
  route an answer into `policyFailure`, this test fails before the
  precondition does — and it fails as a test failure, not as a crashed process
  taking the rest of the suite with it.

A crash test was not written. Calling `policyFailure` directly with
`.succeeded` would mean `preconditionFailure` traps inside a test process,
which aborts the whole run rather than reporting one failing case. The two
tests above pin the same invariant from outside the trap, so nothing is lost.

## F4 — negative `retryAfterSeconds` was not floored

**Before.** `RetryPolicy.delay` clamped only the top:

```swift
        return Duration.seconds(min(requested.seconds, maximumRetryAfter.seconds))
```

`retryAfterSeconds: -5` produced a negative `Duration`.

**After.** Floored at zero, upper clamp untouched:

```swift
        return Duration.seconds(max(0, min(requested.seconds, maximumRetryAfter.seconds)))
```

Unreachable in-repo — `HTTPResponsePayload.retryAfterSeconds` refuses a negative
value and floors an HTTP date in the past at zero, and `DispatchSleeper`
returns immediately for a non-positive interval — so this is for direct callers
of a public API. The comment in the source says so rather than implying the
call site is the only possible one.

### Tests for F4

Three in `RetryPolicyTests`, plus the pre-existing ones left as they were:

- **"a negative Retry-After is floored at zero, not handed back as a negative
  wait"** — `-1`, `-5`, `-3600` and `Int.min` all return `.zero`, asserted both
  as `>= .zero` and as `== .zero`. `Int.min` is in the list because
  `Double(Int.min)` is a large negative magnitude, not a small one.
- **"flooring the bottom does not move the top"** — `60`, `61` and `86400`
  still return `.seconds(60)`.
- **"the computed backoff still stops at eight seconds"** — the default
  `maximumDelay` is still `.seconds(8)`, `backoff(afterAttempt: 10)` is still
  `.seconds(8)`, `backoff(afterAttempt: 1)` is still `.milliseconds(500)`, and
  `delay` with no server instruction still returns the computed backoff
  unchanged at both ends.

The two tests that already pinned this behaviour — "an unreasonable Retry-After
is clamped" (cap at 60s) and "backoff stops growing at the ceiling" (cap at 8s)
— were not edited and still pass.

One more, in `RetryingTransportTests`: **"a negative Retry-After from a server
falls back to the computed backoff"** sends a real `Retry-After: -5` header
through `RetryingTransport` and asserts the recorded delay is
`.milliseconds(500)` — the computed backoff, because the payload refused the
value — and that nothing recorded is negative. This is the end-to-end shape of
the same claim: a server cannot get a negative wait past the sleeper.

The account-safety bound did not move. Default budget is still 3 attempts,
401/403 are still `permanentStatus` and never retried, and `Retry-After` is
still honoured and still capped at 60s.

## F7 — stale test count in a MARK comment

**Before.** `RetryPolicyTests.swift`, `// MARK: - The final attempt`:

> These four tests pin that ordering down.

**After.** Ten. Counted, not guessed:

```
$ awk '/MARK: - The final attempt/,/MARK: - Transport failures/' \
      Tests/SiriusXMNetTests/RetryPolicyTests.swift | grep -c '^    @Test'
10
```

Comment only. No test moved, renamed or changed.

## F8 — transposed worktree name in a doc

`docs/phase-0-scaffolding-fixes.md` named the scratch worktree `sxm-fixes` in
the body and `smx-fixes` in the Cleanup section. The Cleanup line now reads
`sxm-fixes`. One character, nothing else in the file touched, and it is a
separate commit from the code so the typo stays trivially revertable.

## Not verified on macOS

Everything above was run on Linux (Debian 12, Swift 6.1.3, x86_64). Nothing here
was built or tested on macOS. Specifically unverified:

- `.macOS(.v14)` and `swiftLanguageModes [.v6]` are satisfied by the package
  manifest as committed on the base branch and were not changed, but only the
  Linux path through them was exercised.
- `NSLock` usage is untouched by this work, so the macOS-15-only
  `Synchronization.Mutex` concern is unchanged from the base branch — and
  likewise unverified here.
- `DispatchSleeper`'s real timer behaviour on Darwin is untouched. The one
  change that touches a duration reaching it, the F4 floor, was verified
  through `RecordingSleeper`, which records rather than waits.
- No macOS build, no `xcodebuild`, and no device or simulator run.
