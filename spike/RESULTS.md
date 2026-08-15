# Spike results — Roc performance semantics for a CDCL SAT solver

**Compiler:** `nightly-2026-08-13-2fdd90e` (release build; the `roc` on PATH at
`~/programs/roc` is `debug-6d4ad949` with tracy instrumentation and is *not* usable for
benchmarking). **Machine:** macOS 24.6.0, arm64. **Build:** `roc build --opt=speed`.
**Date:** 2026-08-14.

Timing method: wall-clock of the whole process, minimum of 3–7 runs, via `time.perf_counter()`
around `subprocess.run`. Process startup is ~2.3ms and is included unless stated otherwise.
All sizes come from `argv` so nothing is constant-folded at compile time. Every benchmark
prints a checksum that was verified by hand against the closed form.

---

## Q1 — `var $arr = ...; $arr = $arr.set(i, v)?` mutates in place ✅

`q1_flat_set.roc`: N writes into a `List(U64)` of size M, index cycling.

| M | N = 200,000,000 |
|---|---|
| 1,000 | 0.112s |
| 10,000 | 0.110s |
| 100,000 | 0.109s |
| 1,000,000 | 0.109s |

Flat in M across 1000×, and linear in N (0/1M/10M/100M/400M → 2.3/2.7/7.5/54.5/211.1ms).
Cloning would be O(N·M). **`set` under a `var` rebinding mutates in place.**

## Q2 — nested `List(List(_))` CLONES the inner list on every append ❌

`q2_nested.roc`: M inner lists, N appends spread across them. This is the natural
watch-list representation.

Scaling in N at M=1000:

| N | `update` | `flat` (single flat list, reference) |
|---|---|---|
| 800,000 | 0.070s | 0.0026s |
| 1,600,000 | 0.236s (3.4×) | 0.0037s |
| 3,200,000 | 0.978s (4.1×) | 0.0061s |
| 6,400,000 | 5.828s (6.0×) | 0.0105s |

4× per doubling = quadratic. Confirmed by the complementary control, N=3,200,000 fixed:

| M | time |
|---|---|
| 250 | 4.94s |
| 1,000 | 1.16s |
| 4,000 | 0.31s |
| 16,000 | 0.25s |
| 64,000 | 0.17s |

Time falls ~4× per 4× increase in M — the O(N²/M) signature of copying the whole inner
list on each append. Flattens once inner lists get short (N/M small).

All three access shapes behave identically — `List.update`, get-then-set, and the
record-wrapped variant. This matches the `Builtin.roc` source:

```roc
update = |list, index, func|
    Ok(list_replace_unsafe(list, index, func(list_get_unsafe(list, index))).list)
```

`list_get_unsafe` hands `func` a second reference to the inner list, so the append sees
refcount 2 and clones.

**Consequence: no nested lists anywhere in the solver's hot data.**

## Q3 — the flat fallback works, and a record wrapper costs nothing ✅

`q3_flatwatch.roc`: watch lists as one flat `List(U64)` arena of M blocks × `cap` slots,
plus a flat `List(U64)` of per-block counts. Append = write at `block*cap + count`, bump count.

At M=1000, cap=4000, N=3,200,000:

| variant | time |
|---|---|
| `vars` — two separate `var` lists | 0.0108s |
| `record` — both lists in one record, `{ ..$st, blocks: $st.blocks.set(...)? }` | 0.0111s |
| `split` — destructure into vars, rebuild at the end | 0.0114s |
| *(nested version, same workload)* | *1.03s* |

**~93× faster than nested, and the record wrapper is free.** Reading `$st.blocks` out of a
live `$st` to update it does *not* clone the 32MB list. Solver state can live in a record;
it does not need to be a pile of loose `var`s.

## Q4 — bounds checks are not the bottleneck ✅

`q4_bounds.roc`: 200,000 passes over a 1024-element `List(U64)`, 204.8M element reads.

| access shape | time |
|---|---|
| `arr.get(i)?` in a `while` loop | 0.0594s |
| `arr.get(i) ?? 0` | 0.0547s |
| `for x in arr` | 0.0553s |
| `arr.fold(...)` | 0.0555s |

Random-access indexing costs the same as sequential iteration: ~53ms for 204.8M reads,
about **3.9 G reads/sec**, roughly one element per cycle. (The no-list arithmetic "floor"
came out at 6ms — that loop was folded to a closed form and is not a valid baseline.)
`?` vs `??` differed by ~8%, within run-to-run noise here; not worth designing around.

## The headline: flat Roc == C

`q3_ref.c`, same algorithm, `clang -O2`. Isolating the loop by subtracting an `n=0` run:

| | alloc + final fold | full | **loop alone** |
|---|---|---|---|
| Roc (`record`) | 6.81ms | 10.46ms | **3.65ms** |
| C `-O2` | 5.43ms | 9.08ms | **3.65ms** |

3.2M iterations of {modulo, indexed read, two indexed writes} in 3.65ms — **identical**,
bounds checks and all. Roc's ~1.4ms edge in setup is `List.repeat` writing zeros where
`calloc` gets lazily-zeroed pages.

---

## What this means for rocsat

1. **Viable.** On the access pattern that dominates unit propagation, `--opt=speed` Roc is
   not "within a small factor" of C — it is the same. There is no performance argument
   against writing this solver in Roc.
2. **One hard design rule: flat scalar lists only.** Clause arena, watch lists, trail,
   assignment / level / reason / activity arrays — all `List(U32)` or `List(U64)`, indexed
   by integer offset. Any `List(List(_))` in the hot path is a ~100× regression.
   This is what MiniSat does anyway, so the constraint costs nothing in solver design.
3. **State lives in one record**, threaded through `var` rebinding. Confirmed free.
4. **Watch lists need explicit storage management** — fixed-capacity blocks with compaction,
   CSR-style regions, or an intrusive linked list threaded through an index array. This is
   the one place the Roc design differs from a straight MiniSat port, and it needs a real
   decision (see the open questions).

## Open questions this spike did NOT answer

- Watch-list churn under **removal**, not just append. Swap-with-last in a flat block is
  O(1), but blocks that overflow their `cap` need a growth or compaction strategy, and that
  was not measured.
- Whether uniqueness survives **passing the state record into and out of non-inlined
  functions** across a module boundary. Everything here was in one file; the real solver
  will not be. This is the highest-priority follow-up — if a cross-module call breaks
  uniqueness, the design changes again.
- `expect` behavior under `--opt=speed` (docs say it is *not yet* compiled out).
- Whether large `List.repeat` allocations are a startup cost worth avoiding.
- Anything about recursion depth, `Try` in deeply nested calls, or DRAT proof I/O.

## Files

| file | what |
|---|---|
| `q1_flat_set.roc` | Q1 — in-place `set` under `var` |
| `q2_nested.roc` | Q2 — nested list append, 4 shapes |
| `q3_flatwatch.roc` | Q3 — flat block arena, 3 state-threading shapes |
| `q3_ref.c` | C reference for `q3_flatwatch` |
| `q4_bounds.roc` | Q4 — bounds-check / access-shape cost |

Rebuild: `roc build --opt=speed <file>.roc` with the release nightly, not the debug `roc`
on PATH.
