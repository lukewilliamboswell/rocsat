# Interpreter backend cannot produce a runnable hello-world

**Originally verified:** `nightly-2026-08-13-2fdd90e`, arm64 macOS (Darwin 24.6.0).

**Latest nightly:** the backend is still broken on `nightly-2026-08-18-e9be50a`, Linux ARM64,
but with a different symptom: the build reports success and the resulting binary immediately
segfaults. The old nightly has the same Linux behavior. A fresh macOS run is needed before
filing the original linker symptom.

## Problem

The interpreter backend cannot build a runnable hello-world. The three compiled optimisation
levels build and run the same file. The failure is platform-dependent:

- on arm64 macOS, the interpreter build fails to link because `_main` is undefined;
- on Linux ARM64, it reports a successful build, but running the output exits 139 (SIGSEGV)
  without printing anything.

## Reproduce

```sh
roc build --opt=dev         --no-cache hello.roc && ./hello   # prints hello
roc build --opt=speed       --no-cache hello.roc && ./hello   # prints hello
roc build --opt=size        --no-cache hello.roc && ./hello   # prints hello
roc build --opt=interpreter --no-cache hello.roc && ./hello   # link error or SIGSEGV
```

The macOS linker output is:

```
ld64.lld: error: undefined symbol: _main
>>> referenced by the entry point

LINKER FAILED

The linker failed while building for target arm64mac.
Error: LinkFailed
```

On Linux ARM64, both tested nightlies instead print a successful-build message; executing the
result gives exit 139. Rebuilding the other three modes immediately before running them gives
exit 0 and prints `hello`, so the source and host interface work.

## Notes for triage

The macOS output suggests a missing entry stub, while the Linux result shows that a generated
entry point can still be unusable. These may be different platform-specific causes; they are
kept together because both affect the same advertised backend on the same minimal input.

Impact for us is low because we do not use the interpreter backend. This is reportable because
`roc build --help` advertises it and the smallest possible application fails on both tested
platforms.

## Files

| file | what |
|---|---|
| `hello.roc` | a headerless hello-world |
