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

## Q5 — function and module boundaries (follow-up, `q5_boundary/RESULTS.md`) ⚠️

62 code shapes tested. Module boundaries per se are fine. But **mutating a list through a
record field projection** (`st.blocks.set(..)`, `{ ..st, blocks: st.blocks.set(..) }`) is
*fragile*: 28 of 51 record-shaped variants clone the 32 MB list on every operation, and
whether a given shape clones depends on whether the record came from a literal or a call,
whether `?` or `??` was used, and whether the code is in a loop or a callee. Confirmed in
the LLVM IR: the compiler increfs the projected field before `list_set` in the bad shapes.
**Separate `List` values as parameters/returns are robust: 11 of 11 shapes in place**,
including cross-module, `?`, recursion, tuples, `Try`, and rebuilding a record every step.
This supersedes item 3 below.

## Q6 — watch-list churn with removal (`q6_churn/`) ✅

Track A's pooled flat-block scheme (relocation on overflow, in-loop compaction) beats an
intrusive linked list by 25–60 % on a propagate-shaped move workload with a clause arena;
capacity policies cost the same time and differ only in memory; a full rebuild ≈ 10–12 ns
per watch. Full write-up in `research/02-roc-performance.md` Q2.

## Q7 — allocation and growth (`q7_alloc/`) ✅ (one trap)

`List.repeat` fills at ~15 GB/s; `append` grows geometrically; `set`/`drop_last` keep
capacity. **`List.reserve(k)` sets capacity to exactly `len + k` — repeated `reserve` is
quadratic.** Full table in `research/02-roc-performance.md` Q5.

## What this means for rocsat

1. **Viable.** On the access pattern that dominates unit propagation, `--opt=speed` Roc is
   not "within a small factor" of C — it is the same. There is no performance argument
   against writing this solver in Roc.
2. **One hard design rule: flat scalar lists only.** Clause arena, watch lists, trail,
   assignment / level / reason / activity arrays — all `List(U32)` or `List(U64)`, indexed
   by integer offset. Any `List(List(_))` in the hot path is a ~100× regression.
   This is what MiniSat does anyway, so the constraint costs nothing in solver design.
3. ~~State lives in one record, threaded through `var` rebinding.~~ **Revised by Q5:** the
   state record is fine *at rest*, but hot functions must **destructure it into individual
   list bindings on entry, mutate those, and rebuild on exit** — never mutate through
   `st.field`. Helpers take the lists they need as separate parameters and return tuples.
4. **Watch lists need explicit storage management** — fixed-capacity blocks with compaction,
   CSR-style regions, or an intrusive linked list threaded through an index array. This is
   the one place the Roc design differs from a straight MiniSat port, and it needs a real
   decision (see the open questions).
5. **A CI canary benchmark is mandatory** — a timed n-scaling run of the real propagate
   loop — because a future nightly can flip a shape from in-place to cloning silently.

## Open questions this spike did NOT answer

- ~~Watch-list churn under **removal**~~ — Q6 above.
- ~~Whether uniqueness survives passing the state record into and out of non-inlined
  functions across a module boundary.~~ Answered by Q5 (above).
- Why nominal-type method dispatch (`$st.step(..)`) is 3× slower than the equivalent plain
  function call, and whether per-step call overhead (5–14 ns) can be reduced.
- ~~`expect` behavior under `--opt=speed`~~ — dropped in speed/size/default builds, kept in
  `--opt=dev` and `roc run`; see `research/02-roc-performance.md` Q4.
- ~~Whether large `List.repeat` allocations are a startup cost worth avoiding.~~ No — Q7.
- Anything about recursion depth or DRAT proof I/O.

## Files

| file | what |
|---|---|
| `q1_flat_set.roc` | Q1 — in-place `set` under `var` |
| `q2_nested.roc` | Q2 — nested list append, 4 shapes |
| `q3_flatwatch.roc` | Q3 — flat block arena, 3 state-threading shapes |
| `q3_ref.c` | C reference for `q3_flatwatch` |
| `q4_bounds.roc` | Q4 — bounds-check / access-shape cost |
| `q5_boundary/` | Q5 — function/module boundaries, 62 shapes; see its own `RESULTS.md` |
| `q6_churn/` | Q6 — watch-list churn: pooled blocks vs linked list, capacity policies |
| `q7_alloc/` | Q7 — allocation, growth, `reserve` trap |
| `q8_misc/` | unsafe-op reachability, `expect` per backend, basic-cli 0.22.0 test app |

Rebuild: `roc build --opt=speed <file>.roc` with the release nightly, not the debug `roc`
on PATH.
