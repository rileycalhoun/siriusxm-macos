# Test robustness: why the leak assertions were made non-vacuous

This records the reasoning behind commit `4ad4b4e`
(`test(core): guard reflection assertions against an empty mirror`) on
`test/f1-nonvacuous-tests`. It is an argument, not a changelog: it explains
what was wrong with the assertions as they stood, why two different repairs
were needed for two different families of case, and how the repair itself was
shown to work.

**Platform and evidence statement, up front.** Everything below was done on
**Linux**. Nothing in this repository has been compiled or executed on macOS
at any point in this work. Claims are tagged:

- **CONFIRMED** — established by running the test suite on Linux at the stated
  commit, or by reading the file at that commit.
- **UNVERIFIED** — asserted as reasoning, but not reproduced here. Stated as
  reasoning, not as result.

The mutation experiment in the last section is the one that most needs this
distinction, and its status is called out explicitly there.

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
test is green. The renderer could be entirely broken — could return `""`,
could return a placeholder, could not be reached at all — and the assertion
still holds. **"No token in the output" is trivially true of a renderer that
emits nothing.** The test has green-skin for the one failure mode most likely
to be introduced by the next refactor of the rendering path.

This is a *vacuity* defect, not a *wrongness* defect. Nothing was asserting a
false statement. The problem is that the suite could report full coverage of a
leak path while inspecting no output on that path at all — coverage on paper,
silence in fact. For a file whose entire purpose is proving that credentials
cannot escape, that is the worst possible failure mode: it looks exactly like
success.

## Where it actually bit: the reflection tests

`RedactingURL` closes two families of leak. The description protocols
(`CustomStringConvertible`, `CustomDebugStringConvertible`) cover
`String(describing:)`, `String(reflecting:)` and interpolation.
`CustomReflectable` covers `dump()` and `Mirror`, which bypass those
protocols entirely and walk stored properties — that is why the conformance
exists as a separate one, and why the private `url` would otherwise be printed
verbatim.

The mirror it builds carries two children, `rendered` (the already-proven-safe
printable form) and `carriesSensitiveComponents` (the flag). **CONFIRMED** by
reading `Sources/SiriusXMCore/RedactingURL.swift` at `4ad4b4e`.

That is what makes the reflection tests the most exposed in the file, and the
most exposed test of all is `mirrorChildrenCarryNoToken`. The test renders the
mirror's children into a string and asserts the token is absent from it. But
the children come from `customMirror`, and `customMirror` is *the thing under
test*. If it returned `Mirror(self, children: [])` — which is exactly what the
type looks like if the `CustomReflectable` conformance is deleted, or narrowed
to nothing — then `mirror.children` is empty, the mapping yields zero
elements, the join yields `""`, and the absence assertion sails through having
looked at no data whatsoever. **CONFIRMED** by reading the test at `4ad4b4e`
and the type at the same commit.

That is the whole defect, and it is worth being precise about why it is easy to
miss: the test *looks* like it has an anchor. It reads a value out of the
renderer under test and then asserts something about it. The flaw is that the
value it reads can legitimately be nothing.

## Why an emptiness guard is not the whole repair

The obvious repair for the reflection cases is to assert the rendering is
non-empty before asserting the secret is absent. That works — and it is what
several tests in the file do — **but only where the rendering is the entire
string**. That is a much narrower condition than it first appears.

For most of the leak paths in this file, the renderer under test is wrapped in
syntax that survives it. If the inner rendering comes back empty, the outer
string is still non-empty, and the emptiness guard still passes:

- **`Handoff(target:retryable:)`** — a custom `description` of the form
  `"Handoff(\(target))"`. If `target.description` is `""`, the rendering is
  `"Handoff()"`. Non-empty. No token. Both assertions pass. **CONFIRMED** by
  reading.
- **`Playlist(name:entry:)`** — the synthesised description keeps the name.
  An empty entry yields `Playlist(name: "late night", entry: )`. Non-empty, no
  token. **CONFIRMED** by reading.
- **An array** — `["[…]"]`. An element that renders to nothing yields `[()]`.
  The delimiters are always present; they are produced by the collection, not
  by the renderer under test. **CONFIRMED** by reading.
- **A set** — same shape, for the same reason. **CONFIRMED** by reading.
- **A dictionary** — key and value are two separate renderings, so an empty one
  yields `[ : ]`. **CONFIRMED** by reading.
- **`Optional<RedactingURL>`** — `Optional()`, and `Optional(nil as Any)` in the
  sibling case. The wrapper text is there regardless of what the payload does.
  **CONFIRMED** by reading.
- **String interpolation of several values** — `"\(a) then \(b)"` retains its
  own literal `" then "` even if both interpolations render to nothing, so the
  result is never empty. **CONFIRMED** by reading.
- **A synthesised userinfo rendering** — if the renderer returned `""` for a
  URL with embedded credentials, both absence assertions in that test would
  still hold. **CONFIRMED** by reading.

In every one of those cases the emptiness check is not merely insufficient, it
is *actively misleading*: it reports "the renderer produced output" when what
actually happened is "the surrounding syntax produced output and the renderer
produced nothing". A guard that can be satisfied by the thing it is supposed
to be policing is worse than no guard, because it looks like a defence.

### The technique that does work: a positive anchor on `RedactingURL.redaction`

These cases are repaired the other way round. Instead of proving that *some*
output exists, they prove that *the specific output that redaction produces*
is present. `RedactingURL.redaction` is the public constant `<redacted>`; the
rendered form of anything sensitive must contain it. So:

```swift
#expect(rendered.contains(RedactingURL.redaction),
        "the nested value must have rendered the redacted form, not nothing")
#expect(!rendered.contains(Self.secret))
```

The anchor cannot be produced by the surrounding syntax. `Handoff()` does not
contain `<redacted>`. `Playlist(name: "late night", entry: )` does not.
`[()]` does not. `Optional()` does not. `" then "` does not. So if the marker
is present, the renderer under test demonstrably ran and demonstrably took the
redacting path. Only then does the absence assertion mean what it says.

Where a test renders the value **more than once**, the anchor is strengthened
from "at least one" to "exactly as many as there were renderings", by counting
marker occurrences:

```swift
#expect(rendered.components(separatedBy: RedactingURL.redaction).count - 1 == 2)
```

This matters for the compound interpolation literal and for the dictionary,
where there are two renderings. A dictionary that redacts the key but not the
value still contains the marker once, and still contains the secret — but the
presence-only anchor would not have told you that. Counting closes it.
**CONFIRMED** by reading the assertions at `4ad4b4e`.

### Which technique applies where

- **Emptiness guard** — used where the renderer under test is the *whole*
  string, so "the string is non-empty" and "the renderer produced something"
  are the same claim. That is the `Any`-erasure case: `String(reflecting:)`
  on an `Any` unwraps to the concrete type and calls its `debugDescription`,
  with no wrapper text whatsoever, so an empty result really does mean the
  renderer produced nothing. The `mirrorExposesNoURL` tests also guard this
  way, and correctly so: their assertions live inside a `for` loop over
  `mirror.children`, and an empty mirror means the loop body never executes
  and the assertion is never made. Those two tests additionally assert
  `!url.description.isEmpty` first, because both mirror children are derived
  from the rendered form — if the renderer returned `""` the mirror would be
  empty *as a consequence*, and the emptiness of the mirror would be telling
  you about the renderer, not about reflection. **CONFIRMED** by reading.
- **Positive anchor** — used for every container, wrapper, nesting and
  interpolation case above, for exactly the reason that the wrapper text
  survives an empty payload.
- **Both** — used where either is meaningful. The `Any` case carries the
  emptiness guard *and* the anchor; the guard is diagnostic (it names the
  actual failure) while the anchor is what closes the vacuity. The `dump()`
  tests for the path credential carry `!sink.isEmpty` and then
  `sink.contains(RedactingURL.redaction)`.

## The guard: `mirrorVacuityReason`

The reflection tests needed a check with three branches, not one, so it is
written once at the foot of the file as a function returning an optional
reason:

```swift
private func mirrorVacuityReason(_ mirror: Mirror, rendered: String) -> String?
```

`nil` means the mirror can be used as evidence that a secret is absent. A
non-`nil` reason means it cannot. The three branches, in increasing order of
subtlety:

1. **No children.** `mirror.children.isEmpty`. This is the vacuous pass: the
   mirror reflected on nothing, so there is nothing that could contain a
   secret. **CONFIRMED** by reading.
2. **Children that render to nothing.** `rendered.isEmpty`. The same outcome,
   reached without an empty collection — the collection is non-empty but the
   strings it yields are empty. This branch exists so the guard is not merely
   a restatement of branch 1 in a different costume. **CONFIRMED** by reading.
3. **Children that never rendered the redacted form.**
   `!rendered.contains(RedactingURL.redaction)`. The subtlest version: the
   absence assertion still passes, but it is being made over output that was
   never redacted in the first place. This is the case that generalises the
   whole problem — it is the container case, applied to a mirror. A mirror
   that walks the stored `URL` directly is exactly this, and it *does* carry
   the token. **CONFIRMED** by reading.

The rendering itself is factored into `mirrorRendering(_:)` alongside the
guard, deliberately. They are two halves of one question — *is there anything
here to be suspicious of at all?* — and a test that rendered children one way
and checked emptiness another way could drift, at which point the guard would
be policing a string the test never actually asserted about.

### Why a function returning `String?`, and not an inline `#expect`

This is the design decision most worth recording, because it looks like
over-engineering until you try to write the test that justifies it.

`emptinessGuardRejectsAnEmptyMirror` must assert that the guard **fails** on a
deliberately empty mirror. It constructs `ChildlessValue`, a
`CustomReflectable` whose `customMirror` is `Mirror(self, children: [])` —
the shape the value under test would have if the conformance were removed —
and requires the guard to report a reason for it.

If the guard were written inline, at each of the seven call sites, the
condition would be something like:

```swift
#expect(!mirror.children.isEmpty && !rendered.isEmpty && rendered.contains(…))
```

That expression has no seam. To prove it rejects an empty mirror, the
meta-test has to evaluate it against an empty mirror and expect a *failure* —
but an inline `#expect` that evaluates to `false` is a test failure, not a
passing observation. There is no way to say "this expression is supposed to be
false here" without either failing the suite or re-implementing the condition
at the meta-test site, which would be testing a copy rather than the guard
actually being used. Extracting it into a function turns the condition into a
*value* that can be inspected on both sides, which is exactly what a negative
test needs.

The return type is `String?` rather than `Bool` for the same reason. A reason
string is what makes the failure legible when a real mirror regresses: the
`#expect` message is the vacuity reason verbatim, so a green-to-red transition
tells you *which* of the three ways the guard fired, instead of only that one
of three things became untrue.

The meta-test does not only assert that the guard rejects. It also asserts the
guard **accepts** the real mirror — otherwise a guard that returned a reason
unconditionally would pass its own test — and it separately forces branch 2 by
calling the guard with the real mirror's children and an empty rendering
string, and forces branch 3 by mirroring the raw `URL` through
`UnredactedMirrorValue`. So the guard is shown to discriminate, not merely to
reject. **CONFIRMED** by reading the test at `4ad4b4e`.

## The mutation experiment

The claim that needs evidence is the one that justifies the whole change:
that the guards are not decoration, that the repaired tests actually catch the
defect the repair is for, and that the *previous* versions did not.

The mutation is the obvious one — reduce `RedactingURL.customMirror` to
`Mirror(self, children: [])`, which is the shape the type takes if the
`CustomReflectable` conformance is removed, and which is exactly the failure
the guards exist to detect. Under that mutation:

- the guarded `mirrorChildrenCarryNoToken` **should** fail, because the guard
  fires on an empty mirror;
- the same mutation applied to the **pre-`4ad4b4e`** version of that test
  **should** pass, because its only assertion is an absence check over an empty
  string.

That second half is the part that matters. If the previous version also failed
under the mutation, the guard would be fixing nothing.

**STATUS: see the commit history of this document — this section was
originally recorded as UNVERIFIED pending execution, and was updated once the
experiment was run.** The mutation is performed on a throwaway copy of the
tree under `/tmp`; the production source on this branch is unmodified and
`RedactingURLTests.swift` is unmodified, as required.

## What was not changed

No assertion was weakened, removed, or rewritten; no test was deleted. The
work is purely additive — guards and anchors added alongside the absence
checks that were already there. The suite grew by exactly one test, the
meta-test that proves the guard bites.

The one test that is *not* new logic but a new description is the file header,
which claimed reflection was covered by four tests and that each asserted
non-emptiness first. Both claims were inaccurate — there are seven tests that
inspect a real value, and one of them did not assert non-emptiness — so the
header was corrected. A file whose subject is "do not assert things you have
not checked" should not carry unchecked claims in its own header.

### A residual gap, stated plainly

One honest observation about the current state, recorded rather than fixed
because the file is settled and out of scope here.

`pathSecretIsClosedOnEveryDescriptionPath` is an aggregate sweep that runs a
path-bearing URL through ten renderings — including a nested holder, an array,
a dictionary, an `Optional` erased to `Any`, and a bare `Any` — and guards it
with `!rendered.isEmpty` alone. Per the reasoning above, the emptiness guard
does not catch an inner renderer returning `""` for the nested, collection and
`Optional` entries in that list. The positive anchors for those shapes exist,
but they are on the *query*-secret tests (`membershipInADictionaryIsRedacted`,
`erasedByOptionalIsRedacted`, `erasedByAnyIsRedacted`), not on the
*path*-secret sweep. The path secret's bare, `dump()`, and mirror forms are
anchored; its nested forms are emptiness-guarded only. **CONFIRMED** by reading
the file at `4ad4b4e`. This is recorded as a known limitation, not as a
finding against the commit — the commit's own claim was scoped to the tests it
named, and it is accurate about those.
