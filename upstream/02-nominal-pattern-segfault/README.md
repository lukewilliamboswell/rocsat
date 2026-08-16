# Compiler SIGSEGV on a mismatched nominal record pattern in an imported module

**Compiler:** `nightly-2026-08-13-2fdd90e`, arm64 macOS (Darwin 24.6.0).

## Problem

`Sol.roc` declares a nominal record type and destructures it in an associated method with a
pattern that omits one field and has no `..`:

```roc
Sol := { blocks : List(U64), counts : List(U64) }.{
    total : Sol -> U64
    total = |Sol.{ blocks }| blocks.fold(0.U64, |s, x| s + x)
}
```

That is a type error, and checking `Sol.roc` on its own reports it correctly every time
(`INVALID NOMINAL TYPE`, exit 1). But checking or building a module that **imports** it
segfaults the compiler most of the time:

```
Segmentation fault (SIGSEGV) in the Roc compiler.
Fault address: 0x307c6128c

Stack trace:
Cannot print stack trace: stack tracing is disabled

Please report this issue at: https://github.com/roc-lang/roc/issues
```

## Reproduce

```sh
./run.sh            # ROC=/path/to/roc ./run.sh if roc is not on PATH
```

It copies `Sol.roc` and `main.roc` into a fresh temporary directory ten times and runs
`roc check --no-cache main.roc`. Observed exit codes over two batches of ten:

```
139 1 139 139 139 139 139 139 139 1
139 139 139 139 1 139 139 139 1 139
```

So roughly 8–9 crashes in 10; on the other runs the type error is reported normally. Five
consecutive `roc build --opt=speed --no-cache main.roc` runs crashed 5 out of 5. Replacing
`Sol.roc` with `ok.roc` (pattern written `Sol.{ blocks, .. }`) makes everything compile and run.

## Notes for triage

- The crash needs the importing module. `roc check Sol.roc` alone: 10 runs, 10 clean error
  reports.
- It is nondeterministic at a fixed input with `--no-cache`, which suggests uninitialised memory
  or an iteration-order-dependent lookup rather than a deterministic bad index.
- The same class of pattern error the other way round — naming a field the record does not have,
  `|Sol.{ blocks, counts, extra }|` — crashes too.
- We first hit this in August 2026 while writing a spike; it cost an afternoon because the
  crash points at nothing and the file it came from checks clean in isolation.

## Files

| file | what |
|---|---|
| `Sol.roc` | the nominal type with the mismatched pattern |
| `main.roc` | imports and calls it — this is what crashes |
| `ok.roc` | the corrected `Sol.roc`, to confirm the rest of the reproducer is sound |
| `run.sh` | runs the check ten times in fresh directories and prints the exit codes |
