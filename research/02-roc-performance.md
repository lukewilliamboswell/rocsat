# Track B — Roc performance semantics for rocsat

**Compiler:** `nightly-2026-08-13-2fdd90e` (release build). **Machine:** macOS 24.6.0, Apple
Silicon (arm64). **Build:** `roc build --opt=speed` unless stated. **Dates:** 2026-08-14 (Q1),
2026-08-16 (Q2–Q6). Timing method: wall-clock of the whole process, min of 3–7 runs, minus a
zero-work run of the same binary where noted; every benchmark prints a checksum that is
compared across variants. Benchmark sources: `spike/q5_boundary/` (Q1), `spike/q6_churn/`
(Q2), `spike/q7_alloc/` (Q5), and the small files quoted inline (Q3, Q4, Q6). Earlier
settled results (flat `List` in-place `set`, nested lists clone, bounds checks free, flat Roc
== C on the propagate inner loop) are in `spike/RESULTS.md` and are not repeated.

Confidence legend: **measured** = reproduced here on this nightly; **source** = read in the
compiler/platform source at a stated commit; **inferred** = plausible reasoning, not verified.

---

## Verdicts up front

| Q | Verdict |
|---|---|
| Q1 boundaries | Function/module boundaries are fine. Mutating through a record field projection (`st.blocks.set(..)`) is fragile — 28/51 shapes clone the whole list per op. Separate `List` values as params/returns are robust — 11/11. **Design rule: destructure on entry, mutate lists, rebuild on exit.** (measured; `spike/q5_boundary/RESULTS.md`) |
| Q2 churn | Track A's pooled-block scheme (A) beats the intrusive linked list (C) by 25–60% on a realistic churn workload once a clause arena is in the picture, and all its capacity policies cost the same time (±5%); they differ only in memory (2.8×–4.7× the live watch words without compaction). A full rebuild costs ≈10–12 ns per watch entry. `append_range_within` relocation is 5% faster than a manual copy loop. (measured) |
| Q3 escape hatches | `list_get_unsafe` & co. are **not reachable** from application code (`NAME NOT IN SCOPE` / `DOES NOT EXIST` for all three spellings). No plan to expose them was found. "Bounds checks are free" is **not an accident**: PR #10638 (merged 2026-08-06) added a `range_prove` LIR pass that folds provably-true bounds checks under `--opt=speed`/`size`; it is in this nightly. Rely on it, and keep the CI canary. (measured + source) |
| Q4 `expect` | Inline `expect` is **omitted** from `--opt=speed`, `--opt=size` and the default `roc build` (which is speed) — an O(n) expect inside an O(n) loop costs nothing (measured, cold `--no-cache` builds). It is **kept** by `--opt=dev` builds and by `roc run`, where a failure prints `Expect failed` to stderr and execution *continues*. Intentional: PR #9842 (2026-06-28). So O(n) invariant checks are free in release; use `--opt=dev` builds for the fuzz loop. (measured + source) |
| Q5 allocation | `List.repeat` fills at ~15 GB/s (0.25 ns per U32; 64 M U32 in 17 ms) — startup for a 1 M-variable solver's arrays is well under a millisecond per array; not worth avoiding. `append` from empty grows geometrically (1.5 ns/el, linear); `set` keeps capacity; `drop_last` keeps capacity. **Trap: `List.reserve(k)` sets capacity to exactly `len + k` (source), so calling it repeatedly is quadratic — measured 4× per doubling of n.** Reserve once, or just append. Growth goes through host `roc_realloc`. (measured + source) |
| Q6 practicalities | **Use basic-cli 0.22.0** (released 2026-08-14 for the new compiler; built and ran here with `--opt=speed`, hot loop same speed as headerless). It has argv (`List(OsStr)`), `Path.read_bytes!`, `Stdin.read_to_end!`, `Stdout`/`Stderr`, exit codes via `Err(Exit(I32))`, and a **wall-clock** `Utc.now!() : U128` ns (µs resolution here) — no monotonic clock exists anywhere. `roc test` runs top-level `expect`s (dev backend); `roc test --opt=speed` fails to link cold on this nightly (`ld64.lld: library not found for -lSystem`). Generated IR: `roc build --keep-temp` + `llvm-dis`. (measured + source) |

---

## Q1. Uniqueness across function and module boundaries

Answered in full in `spike/q5_boundary/RESULTS.md` (62 code shapes, IR inspection). Summary
of what matters for the rest of this document:

- (a) same-module non-inlined call, (b) cross-module call (void module or nominal-type
  method), (c) `Try` return, (d) tuple/record return, (e) recursion: **all keep in-place
  mutation** when the mutated lists are passed as separate values. Recursion is
  tail-call-optimised (7.5 ms vs 6 ms `while`).
- What breaks it is **mutating a list through a record field projection**, in a way that
  depends on whether the record came from a literal or a call, `?` vs `??`, and whether the
  code is in a loop or a callee. IR shows a spurious `roc_llvm_rc_incref` on the projected
  field before `roc_builtins_list_set`. It is a compiler ownership-inference inconsistency.
- Per-step call overhead: ≈5 ns (record in/out), ≈9 ns (tuple of two lists), ≈14 ns
  (`Try(tuple)`). Nominal-type method dispatch measured 3× a plain call (unexplained).

## Q2. Watch-list churn with removal

**Verdict.** On a propagate-shaped workload — visit a random literal's list, keep ~75% of
entries by in-loop compaction, move ~25% to other lists — Track A's recommended scheme (A:
one flat `List(U32)` pool of 2-word entries, per-literal `wofs/wlen/wcap`, relocation with
doubling on overflow) runs at **48 ns per entry visit** (L = 200 k literals, T = 2 M watches,
8-word clause arena) versus **64 ns for the intrusive linked list** (C), and 72 vs 116 ns at
L = 1 M, T = 10 M. Every capacity/compaction policy for A costs the same time within 5%; the
policies differ only in memory. A full rebuild of the pool costs ≈10–12 ns per live watch
entry (17 ms for T = 2 M, 100 ms for T = 10 M). Confidence: measured; the workload is
synthetic (uniform random literals, constant T), so absolute numbers are cache-miss dominated
and real instances with skewed lists will be faster per visit.

**Benchmark** — `spike/q6_churn/churn.roc` (build with the release nightly, run
`python3 bench.py L T R period stride`). Design:

- Entries are created once (T entries, literal and blocker uniformly random) and only *move*
  afterwards, so T is constant and every scheme holds the same per-literal multiset at every
  step. Move decisions hash `(entry id, step)` so they are independent of traversal order;
  all schemes print the same checksum (verified for every configuration).
- Per step: `p = rng % L`; traverse p's list; for each entry read `val[blocker]` (half the
  literals are "true": kept without touching the clause); otherwise touch the simulated
  clause arena at `arena[cref*stride]` and, with probability ½, move the entry to
  `q = hash % L` (a new watch was found), else keep. Average visit count per step is T/L =
  10, so R = 2 M steps ≈ 20 M entry visits, ≈5 M moves.
- Scheme A `pool*`: in-loop compaction while traversing (kept entries slide down; `wlen[p]`
  is set at the end); `push_watch(q)` relocates q's block to the pool end with doubled
  capacity when full (`append_range_within` for the live words, then again for the padding),
  tracking `garbage`. Policies: initial/compaction capacity = exact / `len + len/2 + 2` /
  next pow2 ≥ 4; compaction when garbage > ¾ of the pool and pool > 2^18 words (Kissat's
  trigger), or unconditionally every `period` steps (simulating rebuild-after-reduce);
  compaction = lay out a fresh pool with the policy's capacities and copy live entries
  (O(T + L), no sort).
- Scheme C `linked`: `head[l]`, and per entry the next-link and blocker live *in the clause
  arena* (`arena[e*stride+1]`, `arena[e*stride+2]`), i.e. every visit dereferences the
  clause — the structural cost Track A §2.3.1 describes. Unlink during traversal (holding
  the predecessor), push-front onto q. Requires stride ≥ 3.

**Raw numbers** (loop = full − R=0 run; ns/visit = loop / (R·T/L); "pool words" is the pool
length at exit; live entry words are 2T = 4 M and 20 M respectively):

L = 200 000, T = 2 000 000, R = 2 000 000, period = 200 000, stride = 8, min of 3:

| mode | loop | ns/visit | relocs | compacts | pool words |
|---|---|---|---|---|---|
| pool (exact, never compact) | 968 ms | 48.4 | 239 767 | 0 | 14.28 M |
| pool_gc (exact, ¾ trigger) | 972 ms | 48.6 | 239 767 | 0 | 14.28 M |
| pool_slack (len+len/2+2) | 949 ms | 47.4 | 79 074 | 0 | 11.17 M |
| pool_pow2 | 970 ms | 48.5 | 151 927 | 0 | 12.87 M |
| pool_loop (manual copy on relocation) | 1015 ms | 50.7 | 239 767 | 0 | 14.28 M |
| pool_period (rebuild every 200 k steps, exact) | 1477 ms | 73.8 | 1 556 014 | 10 | 4.00 M |
| pool_period_slack | 1143 ms | 57.1 | 32 956 | 10 | 6.70 M |
| pool_period_pow2 | 1299 ms | 64.9 | 544 977 | 10 | 5.49 M |
| linked | 1283 ms | 64.1 | — | — | (arena 16 M) |

L = 1 000 000, T = 10 000 000, R = 2 000 000, stride = 8, min of 2:

| mode | loop | ns/visit | relocs | compacts | pool words |
|---|---|---|---|---|---|
| pool | 1444 ms | 72.2 | 871 405 | 0 | 54.4 M |
| pool_slack | 1369 ms | 68.4 | 64 550 | 0 | 36.7 M |
| pool_pow2 | 1377 ms | 68.9 | 367 248 | 0 | 42.6 M |
| pool_loop | 1588 ms | 79.4 | 871 405 | 0 | 54.4 M |
| pool_period (10 rebuilds) | 3360 ms | 168.0 | 3 646 332 | 10 | 20.0 M |
| pool_period_slack | 2450 ms | 122.5 | 703 | 10 | 33.5 M |
| linked | 2314 ms | 115.7 | — | — | (arena 80 M) |

Longer run, L = 200 k, T = 2 M, **R = 8 M** (whole process, includes ~20 ms setup), RSS
includes the 64 MB arena and 16 MB of entry tables:

| mode | time | RSS | pool words at exit |
|---|---|---|---|
| pool | 3.73 s | 271 MB | 18.7 M |
| pool_slack | 3.83 s | 230 MB | 16.4 M |
| pool_pow2 | 3.79 s | 222 MB | 18.0 M |
| linked | 5.36 s | 83 MB | — |
| pool_period_slack, 1 rebuild | 3.76 s | 232 MB | 6.7 M |
| pool_period_slack, 10 rebuilds | 4.05 s | 148 MB | 6.7 M |

Without any clause-arena access (stride = 1, i.e. the compute-only cost of the list
operations themselves), pool is 27 ns/visit; the dense linked list (links in small separate
arrays, measured before the arena was added) was 17 ns/visit vs pool's 25 — the linked list
only wins when its links fit in cache, which they never do in a real solver.

**What this says about the policy question:**

1. **Choose scheme A**, as Track A recommends; the measurement agrees with its reasoning
   (contiguous scan + blocker in the entry avoids the per-visit clause dereference).
2. **Capacity policy does not matter for time.** Exact-fit vs +50% vs pow2 are within noise.
   Choose by memory: `len + len/2 + 2` had the fewest relocations (3× fewer than exact) and
   the smallest pool. With no compaction ever, the pool settles at ≈4× the live watch words
   after 8 M steps (2 M-watch instance: 75 MB pool for 16 MB of live watches). That is
   acceptable but a ¾-garbage compaction trigger (which never fired here because doubling
   slack is not counted as garbage) or a rebuild after each `reduce` bounds it.
3. **Rebuild-after-reduce is affordable but not free**: ≈10–12 ns per live watch (a copy plus
   layout), i.e. roughly the cost of visiting every watch once. With reduces every few
   thousand conflicts it is a small percentage. **But rebuilding with exact-fit capacities
   causes a relocation storm** (1.5 M relocations vs 33 k) — always rebuild with slack.
4. Relocation via `List.append_range_within` (new builtin, PR #10638) is the right primitive:
   5% faster than a manual copy loop and one call per block. Padding the block by
   `append_range_within(newofs, 2*(newcap - wlen))` (copies of the live words; content
   beyond `wlen` is dead) avoids a second allocation for zeros.
5. Absolute cost is memory-bound: 27 ns/visit compute-only vs 48–72 ns with a random arena
   touch on every blocker miss. Real propagate has the same structure, so expect
   ≈15–25 M watch visits/s on large instances from this design in Roc, in line with what the
   flat-Roc == C result predicts.

## Q3. Escape hatches and future-proofing

**Verdict.** The unchecked list primitives are not callable from application code, there is
no sign of a plan to expose them, and bounds-check elimination is a real, deliberate
optimiser pass, not an accident of one nightly. Confidence: measured (reachability), source
(the pass), medium (no plan — absence of evidence on GitHub; Zulip was not searchable).

- `Builtin.roc` declares `list_get_unsafe`, `list_set_unsafe`, `list_swap_unsafe`,
  `list_replace_unsafe`, `list_append_unsafe` at file top level, outside the `Builtin`,
  `List` blocks, "implemented by the compiler, does not perform bounds checks", and uses them
  only inside `List.get/set/swap/replace/append/repeat/drop_swap`. Tried from an app on this
  nightly: `list_get_unsafe(xs, 1)` → `NAME NOT IN SCOPE`; `List.list_get_unsafe` → `DOES
  NOT EXIST`; `Builtin.list_get_unsafe` → `DOES NOT EXIST` (files in
  `spike/q8_misc/unsafe{1,2,3}.roc`).
- Bounds-check elimination: roc-lang/roc **PR #10638** "Optimize hot list loops: new
  bulk-list builtins, range proving, and append promotion" (rtfeldman, merged 2026-08-06):
  a `range_prove` LIR pass ("difference-bound prover … folds always-true bounds checks and
  converts checked arithmetic to unchecked") plus `loop_append_promote`, both only under
  `--opt=speed`/`--opt=size`. Motivation quoted in the PR: a pure-Roc DEFLATE within ~9% of
  libdeflate "while keeping every list access bounds-checked". The same PR added
  `List.append_range_within`, `List.copy_range_within`, `U64.from_le_bytes`. Our
  `nightly-2026-08-13` postdates it, so the "bounds checks are free" measurement in
  `spike/RESULTS.md` Q4 (3.9 G checked reads/s, same as `for`) is the pass working, and the
  `.get(i)?`-in-a-`while`-loop shape is exactly what it targets. Note that unprovable
  patterns (index computed from data, e.g. `pool[wofs[l] + 2*i]`) still carry a compare and
  branch — the churn benchmark above shows this is not what dominates.
- Nothing found in roc-lang/roc issues (searched "get_unsafe", "unchecked get", "unsafe
  list", "bounds check elimination", 2025-06 → 2026-08) about exposing unchecked indexing.
  Zulip could not be searched from here; the question to ask there is in UNRESOLVED.
- Practical position: do not design around unchecked access. If a future nightly regresses
  the pass, the CI canary (Q1 design rule) will show it, and the fallback is
  `.get(i) ?? 0` on data that is known in range — same speed today.

## Q4. `expect` under `--opt=speed`

**Verdict.** Inline `expect`s are stripped from optimised builds and kept in dev builds; a
loop with an O(n) `expect` costs zero in release. This is intentional (PR #9842, merged
2026-06-28: "Optimized builds now omit inline expect conditions before lowering them into
runtime code"). Confidence: measured with cold `--no-cache` builds of every backend.

Test (`spike/q8_misc/exp.roc`): an O(n) `while` loop that does `set` and then
`expect all_small($xs, n)` (true, O(n)) and `expect $xs.len() == n + 1` (false):

| build | n = 100 000 | behaviour |
|---|---|---|
| `roc build --opt=speed` | 0.00 s, also 0.00 s at n = 4 M | both expects gone (quadratic work would be 10^10–10^13 ops) |
| `roc build --opt=size` | 0.00 s | gone |
| `roc build` (default; help text says default is speed) | 0.00 s | gone |
| `roc build --opt=dev` | killed at 60 s after 5 130 lines of `Expect failed: expect failed` | kept; failure prints and **continues** |
| `roc build --opt=interpreter` | `Error: LinkFailed` | could not build on this nightly |
| `roc run` (n = 3 000) | 37.9 s, 3 000 × `Expect failed` | kept, interpreted, continues; exit code 1 |

`roc test`: top-level `expect`s fail the run (exit 1); an inline `expect` failing inside a
function called from a *passing* top-level expect prints `Expect failed` but the test still
counts as passed (dev backend, matches Track C). `roc test --opt=speed --no-cache` on this
nightly fails with `ld64.lld: error: library not found for -lSystem` → `LLVM speed test
backend failed: LinkFailed` (macOS toolchain issue; Track C's earlier "same as dev" result
came from a cached build).

The docs are stale in both directions: `mini-tutorial-new-compiler.md` still says
"`--opt=speed` does not discard `expect`s yet" (also copied into `roc-docs/NOTES.md`), while
the behaviour landed on 2026-06-28.

Consequence for rocsat: put O(n) invariants (`check_watches`, `check_trail`, clause
well-formedness) behind `expect` freely; they are free in release. For *detection*, run the
fuzz loop against an `--opt=dev` binary and grep stderr for `Expect failed` (it does not
abort), and keep the cheap invariants as top-level `expect`s for `roc test`.

## Q5. Allocation and startup

**Verdict.** Allocation is not a startup concern: `List.repeat` runs at memset-like speed
(0.25 ns per U32, 0.5 ns per U64 ≈ 15 GB/s), ten 16 M-element arrays take 64 ms, and a
1 M-variable solver's arrays are sub-millisecond. Growth by `append` is geometric and linear
in total (≈1.5 ns per U32 appended from empty; 3× the pre-sized fill), `set` and `drop_last`
keep capacity. **The one trap is `List.reserve`: it sets capacity to exactly `len + spare`
(no geometric growth), so repeated `reserve(k)` is O(n²) — measured 4× time per doubling of
n.** Confidence: measured (`spike/q7_alloc/`), source (list.zig/utils.zig).

Source facts (roc-lang/roc `src/builtins/list.zig`, `utils.zig`, last changed 2026-08-06):
- The list header is `{ bytes, length, capacity_or_alloc_ptr }`; capacity is stored in the
  header, so a unique list keeps its capacity through `set`/`replace` (`listReplaceInPlace`
  when unique; `makeUnique` clones with capacity = length only when shared).
- Growth (`calculateCapacity`/`geometricGrowth`): if the requested length is not exactly
  `old_capacity + 1` the request is trusted **exactly** (this is what `reserve` hits);
  otherwise geometric: 0 → 64 bytes' worth, ×2 below 4 KiB, ×1.5 in the middle range, ×2
  above 128 KiB. `List.append` = `List.reserve(list, 1)` + `list_append_unsafe`, so appends
  get the geometric path; `List.repeat` = `with_capacity(n)` + a loop of
  `list_append_unsafe` (no explicit memset — LLVM evidently vectorises it, see numbers).
- Reallocation goes `RocList.reallocate` → `utils.unsafeReallocate` → host `roc_realloc`
  when the allocation can be reused, else allocate-and-copy. So an in-place realloc path
  exists and depends on the host's `realloc`.

Measured (`spike/q7_alloc/alloc.roc`, `python3 bench.py 7`; times minus the 1.6 ms process
baseline, min of 7 runs; the full 1 M–64 M table is in `spike/q7_alloc/bench_out.txt`):

| mode | n = 16 M | n = 64 M | ns/element at 64 M |
|---|---|---|---|
| `List.repeat(0.U32, n)` | 3.3 ms | 15.0 ms | 0.23 |
| `List.repeat(0.U64, n)` | 7.0 ms | 30.4 ms | 0.47 |
| `with_capacity(n)` + n `append` | 7.3 ms | 30.6 ms | 0.48 |
| `[]` + n `append` (geometric) | 22.3 ms | 96.2 ms | 1.50 |
| `reserve(k)` every k = 4096 appends | **28.1 s** (1.58 s at 4 M, 82 ms at 1 M) | timeout | **quadratic** |
| hand-tracked doubling `reserve(cap)` when `len == cap` | 25.3 ms | 104.8 ms | 1.64 (≈ plain append) |
| `with_capacity(n)`, then per element `set(0, i)` + `append` | 7.6 ms | 32.0 ms | 0.50 (= pre-sized: **`set` keeps capacity**) |
| clause-arena fill from `[]` (5-lit clauses + 2-word header) | 47.4 ms | 197.6 ms | 3.1 per literal |
| same, `with_capacity` sized up front | 13.6 ms | 57.7 ms | 0.90 per literal |
| 10 × `List.repeat(j, n)` "solver arrays" | 65.0 ms (10 × 16 M) | — | 0.41 |
| append n, `drop_last(n/2)`, append n/2 | 34.8 ms | 143.8 ms | ≈ 1.5 n appends: **`drop_last` keeps capacity** |
| append n, `release_excess_capacity`, append n | 50.3 ms | 215.4 ms | shrink + regrow ≈ +23 ms at 64 M |

Guidance for rocsat:
- Allocate the variable-indexed arrays with `List.repeat` at solve start (or when the
  variable count grows for the incremental API); do not bother with lazy zeroing.
- Grow the clause arena and pool by plain `append`/`append_range_within`; never call
  `reserve` in a loop. If the DIMACS header gives clause/literal counts, one
  `with_capacity` up front makes parsing-time appends 3× cheaper (58 vs 198 ms for 64 M
  literals — irrelevant next to text parsing, but free).
- `Str`/`List(U8)` input: `Path.read_bytes!` gives one `List(U8)`; scan it by index.

## Q6. The practicalities

**Verdict.** Use **basic-cli 0.22.0** (new-compiler release of 2026-08-14; CI pinned to
`nightly-2026-08-13-2fdd90e`, the same nightly we use). It built and ran here with
`--opt=speed`, provides everything a SAT CLI needs except a monotonic clock, and the hot
loop runs at the same speed as under the headerless echo platform. Confidence: measured
(build/run), source (platform/main.roc).

- **Platform history:** the new-compiler port landed on `main` via roc-lang/basic-cli PR #413
  (merged 2026-07-15; PR #423 was the WIP branch, merged into `migrate-zig-compiler`
  2026-06-25). Releases: 0.21.0 (2026-07-28), **0.22.0 (2026-08-14)**. Header:
  ```roc
  app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst" }
  import pf.OsStr
  import pf.Stdout
  main! : List(OsStr) => Try({}, _)
  main! = |args| { ... }
  ```
  `args` includes the executable path first; `OsStr.display(a)` → `Str`. Modules: `Cmd, Env,
  File, Http, IOErr, Locale, OsStr, Path, Random, Sleep, Sqlite, Stdin, Stdout, Stderr, Tcp,
  Tty, Url, Utc`. Confirmed by running (`spike/q8_misc/cli.roc`, 3.4 s cold build incl.
  platform download): `Path.utf8(s).read_bytes!() : Try(List(U8), [PathErr(IOErr, Path), ..])`,
  `Stdout.line!`, `Stderr.line!`, `Err(Exit(3))` → exit code 3, an unhandled `Err` prints
  `Program exited with error: PathErr(NotFound, Path.utf8("/nonexistent"))` and exits 1;
  `Stdin.read_to_end!() : Try(List(U8), _)` and `Stdin.line!` exist (per source);
  `Utc.now!() : U128` nanoseconds since epoch, `Utc.delta_as_nanos/millis`. Successive
  `now!` values were multiples of 1000 ns → **microsecond resolution, wall clock, not
  monotonic**; fine for reporting solve time, not for sub-ms measurement. The q3 workload
  inside this app: 6.5 ms for 3.2 M steps incl. 32 MB allocation — same as headerless.
- **Alternatives:** the Zig/Rust platform templates (lukewilliamboswell, releases 1.x,
  2026-07/08; Zig template needs Zig 0.16) expose only `Stdout/Stderr/Stdin.line!` and
  `List(Str)` args — no files, no clock — so they only make sense if we later want our own
  host (e.g. an mmap'd input, or a monotonic clock, or IPASIR C ABI). The headerless
  "echo" platform embedded in the compiler exposes only `echo!` and args; good for spikes,
  not for the tool.
- **No clock in the stdlib** (grep of `Builtin.roc` for monoton/nanos/clock/instant: nothing;
  Track C found the same). Any timing must come from the platform.
- **Tests:** `roc test file.roc` runs the top-level `expect`s of the module and its imports
  (dev backend), exit 1 on failure, `Ran N tests … passed/failed`. `--opt=speed` for tests
  does not link on macOS on this nightly (Q4). Inline `expect` inside called functions
  reports but does not fail the test.
- **Inspecting generated code:** `roc build --opt=speed --keep-temp --no-cache app.roc`
  leaves `roc_app_llvm_arm64mac_speed_<hash>.bc` (pre-LLVM-opt bitcode) under
  `$TMPDIR/roc/<version>/<id>/`; `/opt/homebrew/opt/llvm/bin/llvm-dis` on it, then grep for
  `roc_llvm_rc_incref` adjacent to `roc_builtins_list_set` — that is how the Q1 clone was
  diagnosed. `roc build --verbose --timings` shows cache statistics and phase timings.
  There is no `--emit-llvm`/`--emit-asm` flag in `roc build --help`.
- **Toolchain notes:** `--output=<path>` (with `=`); the default `--opt` for `roc build` is
  `speed`; `--opt=interpreter` builds fail to link here; `roc build` of a headerless app on
  macOS works despite a source comment about a Linux-only default platform. The debug
  `roc` on PATH is unusable for timing (tracy build); the release nightly must be used.

---

## RECOMMENDED MODULE STRUCTURE

Based on Q1 (`spike/q5_boundary/RESULTS.md`), Q2 and Q5:

1. **State record at rest, lists in flight.** `Solver := { arena : List(U32), pool :
   List(U32), wofs : List(U32), wlen : List(U32), wcap : List(U32), trail : List(U32),
   value : List(U8), level : List(U32), reason : List(U32), ... , counters }` is what
   `solve`/`add_clause`/`assume` take and return. Every function that *mutates* destructures
   the lists it needs on entry (`{ pool, wofs, wlen, wcap, .. } = st` or a parameter
   pattern), binds them as `var $pool = pool` etc., loops, and rebuilds the record on exit
   with record spread `{ ..st, pool: $pool, ... }` — this shape (`l_readrec`) was measured at
   full speed even when done per iteration. **Never `st.pool.set(..)` or
   `{ ..st, pool: st.pool.set(..) }` in a hot path.**
2. **Helpers take separate lists and return tuples**, `Try((a, b), _)` when they can fail;
   `?` inside them is fine. Cross-module (`Propagate.roc`, `Analyze.roc`, `Reduce.roc` as
   void modules `X :: [].{ ... }` with type annotations) costs nothing extra over same-file.
   Nominal-type methods (`st.propagate()`) were 3× slower than plain calls — use plain
   module functions for hot code until that is understood.
3. **Innermost loops are `while` loops or self-tail-recursion inside one function**, not a
   call per watch entry (5–14 ns per call is more than the entry visit's compute).
4. **Storage management is index-based only**: pool relocation with `append_range_within`,
   `+50%` capacity policy, rebuild (with slack) after `reduce`; arena grows by `append`;
   variable arrays via `List.repeat`; no `reserve` in loops.
5. **A CI canary**: an n-scaling timing test of the real `propagate` on a fixed generated
   instance with a hard ceiling — the only way to catch a nightly flipping a shape from
   in-place to cloning, or regressing `range_prove`.
6. **Invariants as inline `expect`s** everywhere (free in release); fuzz with an
   `--opt=dev` binary and grep for `Expect failed`.

## UNRESOLVED

- **Why nominal-type method dispatch is 3× slower than a plain call** (`spike/q5_boundary`
  `nom` 63 ms vs `mod` 22 ms vs inline 6 ms). Experiment: `--keep-temp` IR diff of the two;
  Zulip `#compiler development`: "does `x.method(..)` on a nominal type go through an extra
  copy of the payload?"
- **Whether the record-field-projection clone (Q1) is known/planned to be fixed.** File
  `spike/q5_boundary/repro_seed.roc` and `repro_fallback.roc` as a roc-lang/roc issue
  ("spurious incref on record field before list_set depends on how the record was built");
  ask on Zulip whether the design intends `{ ..st, f: st.f.set(..) }` to be in place.
- **Unchecked indexing exposure**: Zulip question "is there any intention to expose
  `list_get_unsafe`-style access, or is `range_prove` the whole answer?" Low stakes.
- **`roc test --opt=speed` link failure on macOS** (`-lSystem` not found) — likely needs
  the SDK path; not investigated. Only matters if speed-only miscompiles (issue #10620,
  closed) need speed-mode tests; a `--opt=speed` binary run over the CNF corpus covers it.
- **Real-workload validation of Q2**: the churn benchmark uses uniform random literals and
  constant T. The propagate loop of the actual solver on a SAT-competition instance is the
  real measurement — this is the CI canary, and it should be built at milestone 2.
- **Monotonic clock**: none in basic-cli 0.22.0; ask/PR upstream (`Utc.now!` is wall clock).
  Until then use `Utc.now!` for reported times and `hyperfine` externally for benchmarks.
- **Compiler segfault** on a type error in a nominal record pattern (Q1 write-up, "Also
  found") — not minimised; worth an issue.
