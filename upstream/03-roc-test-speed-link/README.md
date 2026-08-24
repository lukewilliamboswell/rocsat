# `roc test --opt=speed` cannot link on macOS: `library not found for -lSystem`

**Originally verified:** `nightly-2026-08-13-2fdd90e`, arm64 macOS (Darwin 24.6.0), Xcode
command-line tools installed (`roc build --opt=speed` links fine on the same machine).

**Latest-nightly status:** does not reproduce. On 2026-08-24, arm64 macOS (Darwin 24.6.0) with
`nightly-2026-08-18-e9be50a` and the complete compiler archive installed, `roc test --opt=speed
--no-cache expect_only.roc` printed `All (1) tests passed in 278.8 ms.` and exited 0; Linux ARM64
passes it too. Kept as evidence, not as a live problem. One caveat for anyone chasing the same
message: an installation holding only the `roc` executable, without the `darwin/usr/lib` directory
shipped beside it, produces an identical `-lSystem` error — but the original run recorded
`roc build --opt=speed` working on the same machine, which that explanation does not fit.

## Problem

Every `expect` in the module fails to link when the tests are run through the speed backend, so
the whole test run reports compiler errors instead of results.

## Reproduce

```sh
roc test --no-cache expect_only.roc               # All (1) tests passed in 7.8 ms.  exit 0
roc test --opt=speed --no-cache expect_only.roc   # fails
```

Output of the second command:

```
ld64.lld: error: library not found for -lSystem


┌────────────────┐
│ COMPILER ERROR ├─  ─────────────────────────────────────────────────────────┐
└┬───────────────┘                                                            │
 │                                                                            │
 │  expect 1 + 1 == 2                                                         │
 │  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾                                                         │
 └────────────────────────────────────────────────────────────────────────────┘
    expect_only.roc:1:1

    LLVM speed test backend failed: LinkFailed

Ran 1 tests in 19.2 ms.:
    0 passed
    0 failed
    1 compiler errors
```

Exit code 1. On a real module the message repeats once per `expect` — 19 of them on our
DIMACS parser, which makes the failure noisy as well as fatal.

## Notes for triage

- `roc build --opt=speed` on the same file, same machine, links without complaint, so the
  linker invocation the ordinary build uses (which must be passing an SDK library search path,
  or `-syslibroot`) differs from the one the speed test backend builds.
- Only `--opt=speed` tests are affected. The default (dev) test backend is fine.
- Impact for us is limited but real: it means `roc test` can only ever exercise the dev backend,
  so a speed-only miscompile cannot be caught by unit tests — only by running a release binary
  over a corpus.

## Files

| file | what |
|---|---|
| `expect_only.roc` | three lines: one top-level `expect` and a `main!` |
