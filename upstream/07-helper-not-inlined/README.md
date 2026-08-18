# A small same-module helper is not inlined into a hot loop (~6.6 ns per call)

**Originally verified:** `nightly-2026-08-13-2fdd90e`, `roc build --opt=speed`, arm64 macOS.

**Latest nightly:** still reproduces on `nightly-2026-08-18-e9be50a`, Linux ARM64. The helper
loops took 18–19 ms versus 4–6 ms inline, retaining the roughly fourfold gap.

## Problem

A four-line, pure, same-module helper that takes two lists and returns them as a tuple is not
folded into the loop that calls it. The call costs about 6.6 ns, roughly three times the body
it wraps, so structuring the code into helpers is a 4× slowdown on the hot path.

```roc
step = |xs, ys, lit, cap, i| {
    k = ys.get(lit) ?? 0
    (xs.set((lit * cap) + k, i) ?? xs, ys.set(lit, k + 1) ?? ys)
}
```

## Reproduce

```sh
roc build --opt=speed inline_vs_call.roc
./inline_vs_call inline_loop 1000 4000 3200000
./inline_vs_call call_loop   1000 4000 3200000
```

Loop time = the `n = 3 200 000` run minus an `n = 0` run of the same binary, min of 5:

| mode | shape | loop |
|---|---|---|
| `inline_loop` | `while` loop, body written out | 6.8 ms |
| `inline_rec` | self-recursive fn, body written out | 8.1 ms |
| `call_loop` | `while` loop calling `step` | 26.3 ms |
| `call_rec` | self-recursive fn calling `step` | 26.8 ms |

All four print the same checksum and all four mutate both lists in place (there is no cloning
here — the lists are separate values, which is the shape that is reliably in place on this
nightly). The gap is 19–20 ms over 3.2 M calls, i.e. ~6 ns per call, against a loop body of
about 2 ns.

## Notes for triage

- Both the `while` and the self-recursive form pay it, so it is not about tail-call handling;
  self-tail-recursion is compiled to a loop as documented and `inline_rec` matches
  `inline_loop`.
- The helper is in the same file, has no annotation, is called from exactly two places, and its
  body is four statements — about as inlinable as a function gets.
- We measured other shapes on the same workload where an equivalent helper *was* folded away
  (a record-in / record-out `step` called from a self-recursive function came out at 7.5 ms,
  the same as its inline version), so the decision is inconsistent rather than uniformly off.
  We did not isolate what flips it.
- Practical effect: to keep a solver's propagate loop at full speed we had to write it as one
  long function instead of the natural helper decomposition.

## Files

| file | what |
|---|---|
| `inline_vs_call.roc` | the four modes above, one file |
| `run.sh` | builds and prints loop time per mode (min of 3 runs) |
