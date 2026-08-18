# Compiler SIGSEGV instead of reporting an invalid nominal record pattern

**Compilers:** `nightly-2026-08-13-2fdd90e` and `nightly-2026-08-18-e9be50a`, Linux ARM64.
The original two-file form also reproduced on the older nightly on arm64 macOS.

## Problem

A nominal record pattern with neither the record's field nor `..` is a type error:

```roc
A := { a : Str }.{
    f : A -> Str
    f = |A.{}| ""
}

main! = |_| Ok(echo!(A.f(A.{ a: "" })))
```

When the invalid function is used by the app, both `roc check` and `roc build --opt=speed`
segfault instead of reporting `INVALID NOMINAL TYPE`. Adding `..` to the pattern makes the file
check cleanly:

```roc
f = |A.{ .. }| ""
```

## Reproduce

From this directory, with the latest nightly:

```sh
roc version
roc check --no-cache main.roc
echo $?
```

Observed output and exit code:

```
Segmentation fault (SIGSEGV) in the Roc compiler.
Fault address: 0x...

Stack trace:
Cannot print stack trace: stack tracing is disabled

Please report this issue at: https://github.com/roc-lang/roc/issues
139
```

The crash occurred in 20 of 20 uncached checks on each compiler listed above. A speed build also
exited 139 on both. The corrected control is:

```sh
roc check --no-cache ok.roc    # No errors found; exit 0
```

## Minimization notes

- No import, second source file, collection type, fold, constructor helper, or multi-field record
  is needed. The reproducer is one app file, one one-field nominal record, and one associated
  function.
- Removing the call from `main!` makes the compiler report `INVALID NOMINAL TYPE` correctly.
  The crash occurs when the invalid function reaches app/effect checking through `echo!`.
- Removing the function signature also avoids the crash and reports the type error correctly.
- The earlier reproducer appeared to make direct `roc check Sol.roc` crash because its sibling
  `main.roc` imported and exercised that module. The old `Sol.roc` copied by itself reported the
  type error correctly; the single-file form removes that ambiguity.

## Files

| file | what |
|---|---|
| `main.roc` | minimal crashing app |
| `ok.roc` | same app with `..` added to the nominal pattern |
| `run.sh` | runs ten uncached checks and prints their exit codes |
