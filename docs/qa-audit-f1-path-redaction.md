# QA Audit: F1 Path-Secret Redaction (fix/f1-path-redaction, HEAD d1e945f)

Read-only adversarial audit. Linux (Swift toolchain at /opt/swift/usr/bin). **Nothing has compiled or run on macOS.** This file is updated as the work proceeds (pushed early for durability).

## Status: IN PROGRESS

## Preliminary findings (unverified, to be confirmed/refuted)
- [ ] F1-1 Percent-encoding divergence Linux vs Darwin (t%6Fken%62blob decode case)
- [ ] F1-2 Test header says "four tests", file has seven; two reflection tests lack non-emptiness guard
- [ ] F1-3 SiriusXMEndpoint.displayTarget renders raw path accessor, bypasses redaction
- [ ] F1-4 Sub-12-char and word-shaped credentials not caught (siriusxmsubscriberid, bearer, matrix params)

## Checklist
- [ ] Read RedactingURL.swift in full
- [ ] Read RedactingURLTests.swift in full (vacuous/self-referential assertions)
- [ ] Read Endpoints.swift displayTarget
- [ ] Attack: description/debugDescription/Mirror/dump/nesting/os_log paths
- [ ] Over-redaction: resolvedURL/request-building untouched; <redacted> idempotent
- [ ] swift build + swift test on Linux
- [ ] Revert-experiment: confirm/refute the 17 test failure claim
- [ ] Final verdict on sub-12/word-shaped gap
