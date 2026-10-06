# Test robustness: why the leak assertions were made non-vacuous

This records the reasoning behind commit `4ad4b4e`
(`test(core): guard reflection assertions against an empty mirror`) on
`test/f1-nonvacuous-tests`. It is an argument, not a changelog: what was wrong
with the assertions as they stood, why two different repairs were needed for
two different families of case, and what evidence was produced to show the
repairs actually bite.

**Platform and evidence statement, up front.** Everything below was done on
**Linux** (Swift 6.1.3, `x86_64-unknown-linux-gnu`). Nothing in this
repository has been compiled or executed on macOS at any point in this work.
Claims are tagged:

- **CONFIRMED** — established by running the test suite on Linux at the stated
  commit, or by reading the file at that commit. Observed output is quoted.
- **UNVERIFIED** — asserted as reasoning, not reproduced here.

The section on mutation evidence is the one that most needs the distinction;
it is marked and it was in fact executed.

## The defect class

Almost every security test in this file asserts the same shape:

```swift
#expect(!rendered.contains(Self.secret))
```

That assertion answers one question — *does the output contain the secret?* —
and it answers it correctly. What it cannot answer is the question the test
exists to answer: *did the renderer under test actually run, and produce
output, before we decided it was safe?*

Those two questions collapse into one whenever the renderer emits nothing.
`"".contains(secret)` is `false`, so `!"".contains(secret)` is `true`, and the
test is green. The renderer could be entirely broken — return `""`, return a
placeholder, never be reached at all — and the assertion still holds.
**"No token in the output" is trivially true of a renderer that emits
nothing.** The suite has green-skin for the one failure mode most likely to be
introduced by the next refactor of the rendering path.

This is a *vacuity* defect, not a *wrongness* defect. Nothing asserted a false
statement. The problem is that the suite could report full coverage of a leak
path while inspecting no output on that path at all — coverage on paper,
silence in fact. For a file whose entire purpose is proving credentials cannot
escape, that is the worst available failure mode, because it is
indistinguishable from success in a passing test run.

## Where it actually bit: the reflection tests

`RedactingURL` closes two families of leak. The description protocols
(`CustomStringConvertible`, `CustomDebugStringConvertible`) cover
`String(describing:)`, `String(reflecting:)` and interpolation.
`CustomReflectable` covers `dump()` and `Mirror`, which bypass those protocols
entirely and walk stored properties — which is why the conformance exists as a
separate one, and why the private `url` would otherwise be printed verbatim.

The mirror it builds carries two children, `rendered` (the already-proven-safe
printable form) and `carriesSensitiveComponents` (the flag). **CONFIRMED** by
reading `Sources/SiriusXMCore/RedactingURL.swift` at `4ad4b4e`.

That is what makes the reflection tests the most exposed in the file, and the
most exposed test of all is `mirrorChildrenCarryNoToken`. It renders the
mirror's children into a string and asserts the token is absent. But the
children come from `customMirror`, and `customMirror` is *the thing under
test*. If it returned `Mirror(self, children: [])` — exactly what the type
looks like if the `CustomReflectable` conformance is deleted or narrowed to
nothing — then `mirror.children` is empty, the mapping yields zero elements,
the join yields `""`, and the absence assertion sails through having looked at
no data whatsoever. **CONFIRMED** by reading.

Worth being precise about why this is easy to miss: the test looks like it has
an anchor. It reads a value out of the renderer under test and then asserts
about it. The flaw is that the value it reads can legitimately be nothing.

## Why an emptiness guard is not the whole repair

The obvious repair is to assert the rendering is non-empty before asserting
the secret is absent. That works — and it is what several tests do — **but
only where the rendering is the entire string**. That is a far narrower
condition than it first appears.

For most leak paths in this file the renderer under test is wrapped in syntax
that survives it. If the inner rendering comes back empty, the outer string is
still non-empty, and the emptiness guard still passes. This was not reasoned
about on paper only; mutation C below forces the renderer to return `""` and
prints what each wrapper actually produces:

| Case | Rendering when the inner renderer emits nothing | Non-empty? |
| --- | --- | --- |
| `Handoff(target:retryable:)` | `Handoff()` | yes |
| `Playlist(name:entry:)`, `describing` | `Playlist(name: "late night", entry: )` | yes |
| `Playlist(name:entry:)`, `reflecting` | `SiriusXMCoreTests.RedactingURLTests.….Playlist(name: "late night", entry: )` | yes |
| Array, one element | `[]` | yes |
| Set, one element, `describing` | `Set([])` | yes |
| Set, one element, `reflecting` | `[]` | yes |
| Dictionary, one pair | key and value render empty; delimiters remain | yes |
| `Optional<RedactingURL>` | `Optional()` | yes |
| Compound literal `"\(a) then \(b)"` | `" then "` | yes |
| `Any` | `""` | **no** |

**All rows CONFIRMED** — observed output from the run described under
mutation evidence below, on Linux.

Two things fall out of that table. First, the emptiness guard is not merely
insufficient for eight of the nine cases — it is *actively misleading*, because
it reports "the renderer produced output" when what actually happened is "the
surrounding syntax produced output and the renderer produced nothing". A guard
that can be satisfied by the very thing it is meant to police is worse than no
guard, because it looks like a defence. Second, the `Any` row is the one case
where emptiness genuinely *is* the failure signature, and it is the only case
where the emptiness check does real work on its own.

One incidental observation, recorded because it is a platform difference and
this file elsewhere takes platform differences seriously: the source comment in
`membershipInAnArrayIsRedacted` says the vacuous rendering would be `[()]`.
On Linux the empty element renders as nothing at all, giving `[]`. Both are
non-empty strings, which is the entire point the comment is making, so the
argument is unaffected — but the literal in the comment is not what this
platform prints. **CONFIRMED** by observation; the comment is left as-is,
since the test file is settled and out of scope for this document.

### The technique that does work: a positive anchor on `RedactingURL.redaction`

Those cases are repaired the other way round. Instead of proving that *some*
output exists, they prove that *the specific output redaction produces* is
present. `RedactingURL.redaction` is the public constant `<redacted>`; the
rendered form of anything sensitive must contain it. So:

```swift
#expect(rendered.contains(RedactingURL.redaction),
        "the nested value must have rendered the redacted form, not nothing")
#expect(!rendered.contains(Self.secret))
```

The anchor cannot be produced by the surrounding syntax. `Handoff()` does not
contain `<redacted>`. `Playlist(name: "late night", entry: )` does not. `[]`
does not. `Optional()` does not. `" then "` does not. So if the marker is
present, the renderer under test demonstrably ran and demonstrably took the
redacting path. Only then does the absence assertion mean what it says.

Where a test renders the value **more than once**, the anchor is strengthened
from "at least one" to "exactly as many as there were renderings":

```swift
#expect(rendered.components(separatedBy: RedactingURL.redaction).count - 1 == 2)
```

This matters for the compound interpolation literal and for the dictionary,
which have two renderings each. A dictionary that redacts the key but not the
value still contains the marker once *and* still contains the secret — a
presence-only anchor would not have distinguished that. Counting closes it.
**CONFIRMED** by reading.

### Which technique applies to which case, and why

- **Emptiness guard** — for the `Any`-erasure case. `String(reflecting:)` on
  an `Any` unwraps to the concrete type and calls its `debugDescription` with
  no wrapper text at all, so an empty result really does mean the renderer
  produced nothing (the table's last row). The `mirrorExposesNoURL` tests also
  guard this way, and correctly so: their assertions live inside a `for` loop
  over `mirror.children`, and an empty mirror means the loop body never runs
  and the assertion is never made. Those two additionally assert
  `!url.description.isEmpty` *first*, because both mirror children are derived
  from the rendered form — if the renderer returned `""` the mirror would be
  empty as a *consequence*, and the emptiness of the mirror would be telling
  you about the renderer, not about reflection. Guarding the mirror's
  emptiness without guarding the renderer's would be circular. **CONFIRMED**
  by reading.
- **Positive anchor** — for every container, wrapper, nesting and interpolation
  case in the table, for the reason that the wrapper text survives an empty
  payload.
- **Both** — where either is meaningful. The `Any` case carries the emptiness
  guard *and* the anchor: the guard is diagnostic, naming the actual failure
  mode, while the anchor is what closes the vacuity. The `dump()` tests for the
  path credential carry `!sink.isEmpty` and then
  `sink.contains(RedactingURL.redaction)`, for the same reason — `dump()` writes
  a type header even for an empty payload, so a non-empty sink is no evidence
  that the payload was redacted.

## The guard: `mirrorVacuityReason`

The reflection tests needed a check with three branches, not one, so it is
written once at the foot of the file as a function returning an optional
reason:

```swift
private func mirrorVacuityReason(_ mirror: Mirror, rendered: String) -> String?
```

`nil` means the mirror can be used as evidence that a secret is absent; a
non-`nil` reason means it cannot. Three branches, in increasing order of
subtlety:

1. **No children** — `mirror.children.isEmpty`. The vacuous pass: the mirror
   reflected on nothing, so nothing can contain a secret. **CONFIRMED** by
   reading, and fired directly under mutation A.
2. **Children that render to nothing** — `rendered.isEmpty`. The same outcome
   reached without an empty collection: the collection is non-empty but the
   strings it yields are empty. This branch exists so the guard is not merely
   branch 1 restated in a different costume. **CONFIRMED** by reading; forced
   directly by the meta-test rather than by a real mutation.
3. **Children that never rendered the redacted form** —
   `!rendered.contains(RedactingURL.redaction)`. The subtlest version: the
   absence assertion still passes, but it is being made over output that was
   never redacted. This generalises the whole problem — it is the container
   case, applied to a mirror. A mirror that walks the stored `URL` directly is
   exactly this, and it *does* carry the token. **CONFIRMED** by reading, and
   fired directly under mutation C below.

The rendering is factored into `mirrorRendering(_:)` alongside the guard,
deliberately. They are two halves of one question — *is there anything here to
be suspicious of at all?* — and a test that rendered children one way and
checked emptiness another could drift, at which point the guard would be
policing a string the test never actually asserted about.

### Why a function returning `String?`, and not an inline `#expect`

This is the design decision most worth recording, because it looks like
over-engineering until you try to write the test that justifies it.

`emptinessGuardRejectsAnEmptyMirror` must assert that the guard **fails** on a
deliberately empty mirror. It constructs `ChildlessValue`, a
`CustomReflectable` whose `customMirror` is `Mirror(self, children: [])` — the
shape the value under test would take if the conformance were removed — and
requires the guard to report a reason for it.

Written inline at each of the seven call sites, the condition would be
something like:

```swift
#expect(!mirror.children.isEmpty && !rendered.isEmpty && rendered.contains(…))
```

That expression has no seam. To prove it rejects an empty mirror, the meta-test
has to evaluate it against an empty mirror and expect a *failure* — but an
inline `#expect` that evaluates to `false` is a test failure, not a passing
observation. There is no way to say "this expression is supposed to be false
here" without either failing the suite, or re-implementing the condition at
the meta-test site — which would be testing a copy rather than the guard
actually in use. Extracting it into a function turns the condition into a
*value* that can be inspected from both sides, which is exactly what a negative
test requires.

The return type is `String?` rather than `Bool` for the same reason. A reason
string makes a real regression legible: the `#expect` message is the reason
verbatim, so a green-to-red transition says *which* of the three ways the guard
fired rather than only that one of three things became untrue. Both branches
were observed firing for real — branch 1 under mutation A, branch 3 under
mutation C, quoted below. **CONFIRMED.**

The meta-test does not only assert that the guard rejects. It also asserts the
guard **accepts** the real mirror — otherwise a guard returning a reason
unconditionally would pass its own test — and separately forces branch 2 by
calling the guard with the real mirror and an empty rendering string, and
branch 3 by mirroring the raw `URL` through `UnredactedMirrorValue`. So the
guard is shown to discriminate rather than merely to reject. **CONFIRMED** by
reading.

## The mutation evidence

The claim that justifies the whole change is that the guards are not
decoration: the repaired tests catch the defect the repair is for, and the
*previous* versions did not.

All three mutations below were run on Linux against throwaway copies of the
tree under `/tmp`. The production source and the test file on this branch are
unmodified — `git diff --name-only 4ad4b4e HEAD` on
`test/f1-test-robustness` lists only this document.

**Baseline.** `4ad4b4e`: `Test run with 263 tests passed`. Parent `d1e945f`:
`Test run with 262 tests passed`. **CONFIRMED** — the suite grew by exactly
one test, the meta-test that proves the guard bites.

### Mutation A — reduce `customMirror` to an empty mirror

`Mirror(self, children: [])` in place of the two-child mirror. Result:
`Test run with 263 tests failed with 7 issues`, five tests red:

```
✘ "Mirror exposes no child carrying the token"
    :141  mirrorVacuityReason(...) → "an empty mirror makes this test vacuous") == nil
    :144  (rendered → "").contains("<redacted>")
✘ "Mirror exposes no child carrying a path-embedded credential"
    :204  !((rendered → "").isEmpty → true → true)
    :206  (rendered → "").contains("<redacted>")
✘ "Mirror exposes no URL at all, not even a partial one"
    :219  !((mirror.children).isEmpty → true → true)
✘ "Mirror exposes no URL for a path-embedded credential either"
    :232  !((mirror.children).isEmpty → true → true)
✘ "the emptiness guard rejects an empty mirror"
    :173  (mirrorVacuityReason(realMirror, …) → "an empty mirror makes this test vacuous") == nil
```

Note what did *not* fail: `mirrorChildrenCarryNoToken`'s absence assertion at
line 143, `!rendered.contains(Self.secret)`. It passed, with `rendered` being
the empty string. That is the defect, caught in the act. **CONFIRMED.**

### Mutation B — the same mutation, with the pre-`4ad4b4e` test body restored

`mirrorChildrenCarryNoToken` reverted to its previous form: render the
children inline, assert only `!rendered.contains(Self.secret)`. Everything
else — including the still-mutated `customMirror` — unchanged.

```
✔ Test "Mirror exposes no child carrying the token" passed
  Test run with 263 tests failed with 5 issues
```

**The previous version of the test passes under the mutation that the guarded
version catches.** That is the load-bearing result. If the old test had also
failed, the guard would be fixing nothing. **CONFIRMED.**

### Mutation C — make the renderer emit nothing

The full `4ad4b4e` test file, unmutated, with `description` returning `""`.
This one is about the container cases rather than the mirror. Every one of the
following failed **at a guard or anchor line, and not at any absence-assertion
line**:

```
:276  (rendered → "Handoff()").contains("<redacted>")
:293  (rendered → "Playlist(name: "late night", entry: )").contains("<redacted>")
:308  (rendered → "[]").contains("<redacted>")
:319  (rendered → "Set([])") / (rendered → "[]") .contains("<redacted>")
:332  (rendered.components(separatedBy: "<redacted>").count - 1 → 0) == 2
:358  (rendered → "Optional()").contains("<redacted>")
:371  !((rendered → "").isEmpty → true → true)          ← the Any case
:372  (rendered → "").contains("<redacted>")
:257  (rendered.components(separatedBy: "<redacted>").count - 1 → 0) == 2
:394  (String(describing: url) → "") == "https://<redacted>@example.invalid/a"
:141  mirrorVacuityReason(...) → "a mirror that never rendered the redacted form …")
:114  (sink → "▿ ").contains("<redacted>")
```

Not one failure landed on a `!…contains(secret)` assertion. Every absence
check in this file held under a renderer that was producing nothing at all,
and every one of them was caught by something added at `4ad4b4e`. The
`Any`-erasure case is the only one where the emptiness guard fired at all, and
it fired because — and only because — that rendering has no wrapper syntax
around it. **CONFIRMED**, and this is the direct demonstration that the anchor
technique was necessary rather than merely tidy.

## What was not changed

No assertion was weakened, removed or rewritten; no test was deleted. The work
is purely additive — guards and anchors placed alongside the absence checks
that were already there. The only non-additive edit is the file header, which
claimed reflection was covered by four tests and that each asserted
non-emptiness first. Both claims were inaccurate — there are seven tests that
inspect a real value, and one of them did not assert non-emptiness — so the
header was corrected. A file whose subject is *do not assert things you have
not checked* should not carry unchecked claims in its own header.

### A residual gap, stated plainly

Recorded rather than fixed, because the test file is settled and out of scope
here — but it was confirmed empirically, so it should not be left merely as an
opinion.

`pathSecretIsClosedOnEveryDescriptionPath` is an aggregate sweep that runs a
path-bearing URL through ten renderings — a nested holder, an array, a
dictionary, an `Optional` erased to `Any`, and a bare `Any` — and guards them
with `!rendered.isEmpty` alone. Per the table above, that guard cannot catch an
inner renderer returning `""` for the nested, collection and `Optional`
entries. The positive anchors for those shapes exist, but on the *query*-secret
tests (`membershipInADictionaryIsRedacted`, `erasedByOptionalIsRedacted`,
`erasedByAnyIsRedacted`), not on the *path*-secret sweep.

**CONFIRMED empirically:** under mutation C, `description` returned `""` for
every URL including the path-bearing one, and
`pathSecretIsClosedOnEveryDescriptionPath` was not among the failures. Its
ten renderings all came back non-empty — `"[]"`, `"Optional()"`,
`"Playlist(...)"`-shaped wrapper text — and its absence assertions therefore
passed over output that contained no redaction at all.

This is not a finding against `4ad4b4e`. That commit's claim was scoped to the
tests it named and is accurate about those; this is the boundary of that
scope, made explicit. The path secret's bare, `dump()` and mirror forms are
anchored. Its nested forms are not. **CONFIRMED.**
