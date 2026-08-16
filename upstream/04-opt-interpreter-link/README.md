# `roc build --opt=interpreter` fails to link: `undefined symbol: _main`

**Compiler:** `nightly-2026-08-13-2fdd90e`, arm64 macOS (Darwin 24.6.0).

## Problem

The interpreter backend cannot build a hello-world. The other three optimisation levels build
and run the same file.

## Reproduce

```sh
roc build --opt=dev         --no-cache hello.roc   # ok
roc build --opt=speed       --no-cache hello.roc   # ok
roc build --opt=size        --no-cache hello.roc   # ok
roc build --opt=interpreter --no-cache hello.roc   # fails
```

Output of the last command (with `--verbose`):

```
ld64.lld: error: undefined symbol: _main
>>> referenced by the entry point

LINKER FAILED

The linker failed while building for target arm64mac.
Error: LinkFailed
```

Without `--verbose` only the last three lines appear.

## Notes for triage

- The object the interpreter backend produces has no `main` for the entry point to reference,
  so this looks like a missing host/entry stub rather than a toolchain configuration problem —
  unlike the `-lSystem` failure in `03-roc-test-speed-link`, which is about library search paths.
- Low impact for us: we never needed `--opt=interpreter`. Reported because `roc build --help`
  advertises it and it fails on the smallest possible input, which makes it look untested on
  this target.

## Files

| file | what |
|---|---|
| `hello.roc` | a headerless hello-world |
