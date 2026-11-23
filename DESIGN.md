# rocsat design decisions

This records durable implementation choices whose rationale is not obvious from the code. The
source is authoritative for current behavior; `research/` describes the alternatives considered,
and `upstream/` contains the Roc compiler evidence that constrained the representation.

## Representation and ownership

- Literals use MiniSat's `2*var + sign` `U32` encoding. Clauses share one flat `U32` arena, and
  watches share one pooled flat array. A natural nested-list watch representation was rejected
  because Roc copies an inner list before mutation on the pinned compiler
  ([upstream issue 05](upstream/05-nested-list-clone/)).
- Solver state is a record at API boundaries, but hot mutating functions take individual lists and
  return them in tuples. Record threading silently copied large fields in the measured call shapes
  ([upstream issue 01](upstream/01-record-field-clone/)). `Core.put` is the single write shape, and
  owner loops keep lists in `var`s between calls. Reconsider this only after a new compiler passes
  `make canary` and representative benchmarks.
- Optimized builds are not the only way the engine runs: `roc test` uses the dev backend, and a
  client's top-level constant is evaluated by the compiler. Neither specializes a helper typed
  over `List(a)`, which then copies the list on every call, so `put` exists once per element type
  (`put`, `put_u8`, `put_f64`); neither writes into a list of lists in place, so the public API
  hands the engine clauses as one flat literal list; and both keep inline `expect`s, so
  `Solver.add_all` carries no check that walks the formula. Each of the three made loading
  quadratic there: 8,000 three-literal clauses took 4.7 s as a compile-time constant and take
  20 ms now, and the dev backend solves `hole7` in 2.7 s instead of 26 s. An optimized build
  is unaffected by all three.
- The trail and heap are fixed-capacity indexed buffers with explicit live lengths. The original
  claim that list truncation destroyed uniqueness did not reproduce, but changing these buffers
  would alter the hottest propagation/backtrack storage and therefore remains a separately measured
  simplification, not incidental cleanup.

## Search and learned-clause lifecycle

- Branching is deterministic EVSIDS with lower variable IDs winning equal-activity ties. Full phase
  saving occurs while erasing the backtracked trail suffix. Conflict analysis returns every visited
  variable for activity bumps; minimization does not change that bump set.
- An activity rescale rounds, and after about four of them (18,000 conflicts) underflows scores
  that were bumped only early to zero, so distinct scores become equal while the heap still holds
  them in their old order. `Branch.bump_all` therefore reorders the heap after a rescale. Without
  that the heap stayed a valid max-heap on activity, so only the lower-ID tie rule was broken and
  no answer could change, but the inline heap check failed at later restarts.
- Restarts use the Luby sequence with a 1,000-conflict unit. MiniSat's unit 100 remained pathological
  on `hole10` even after lifecycle support (128.59 s and 2.37 million conflicts), while unit 1,000
  completed it in 41.62 s and 847 thousand conflicts. A 100,000-conflict unit was rejected because
  it effectively hid the restart/database interaction instead of fixing it.
- Reduction runs every 2,000 conflicts and deletes half of stale eligible clauses, ranked by worse
  LBD and then size. Binaries, locked reasons, glue-2 core clauses, and recently used low-LBD clauses
  survive. A 15,000-conflict interval left `hole9` at 38.3 s, while early pressure-triggered deletion
  increased work on `hole8`; the current interval was the measured simpler policy.
- LBD is computed exactly at learn time by temporarily reusing analysis marks. It is not recomputed
  downward on use: mutating the arena inside analysis reintroduced the compiler ownership shape
  that made the prototype six times slower. Use aging still protects active clauses.
- `Reduce.maybe` is an unconditional ownership boundary. Moving its condition into the owner loop
  retained list aliases on the pinned compiler and slowed `hole8` from 1.95 s to 13.3 s even when
  no reduction occurred.
- A conflict budget is exact. The owner loop tests it once per iteration, before propagating, so
  the loop ends right after the conflict that reaches the budget has been analysed and its clause
  learned, and `search_loop` then cancels to the root as a restart does. Nothing sits in the
  conflict path, the restart schedule does not know about the budget, and an unlimited search is
  unchanged decision for decision. MiniSat's shape, a test only where the search is about to
  branch, was the first version and was dropped: directly consecutive conflicts overshot the
  budget (1,001 on a budget of 1,000), which a caller that budgets several calls from one total
  has to work around. The price is one state a restart never produces: when the last conflict
  taught a unit clause, that literal is on the root trail and not yet propagated. Every entry
  point already resumes propagation from `qhead`, so the next solve or clause addition finishes
  it. The cancel is spelled out in the loop function. Calling `Solver.to_root` on the repacked
  record instead changed how `to_root` is compiled for its other callers: `Rocsat.grow` then
  copied the activity list on every `new_var` (4.35 MB requested for 1,024 variables instead of
  0.16 MB), which the allocation fuzz target caught.
- Preferred literals are soft assumptions that belong to one call. `Solver.solve` appends them to
  the assumptions, and the loop gives every position a decision level as it already did; a
  position past the real assumptions whose literal is already false gets a dummy level instead of
  ending the search. One list that the loop only reads supplies both the branching order and a
  sign that phase saving cannot overwrite, without a new list in the owner loop or any change to
  `Branch`. Because the listed literals are always decided first, in order and with their own
  sign, each model is the lexicographically best one for the list. Keeping the list in the state
  was the first version and was dropped: a preference set for one query then steered every later
  one until it was cleared. A pinned bit in the phase byte was rejected earlier: it needs a
  read-modify-write in `Branch.backtrack`, and without a fixed order it promises nothing about
  the model.
- Arena collection starts when dead words exceed one sixth of total storage, the exact threshold
  that restores total arena size to at most 1.2 times live storage after collection. Reduction
  rebuilds watches before tracing deletions, so no stale watcher can reach a deleted clause.
- Root simplification builds a fresh arena rather than adding more tombstones. Permanent root
  reasons are cleared first; proof order is root units, strengthened-clause addition, then old-clause
  deletion.

## API boundaries

- `Rocsat` owns conversion between public nonzero signed `I32` literals and the internal encoding.
  This keeps storage details out of the public contract and out of callers.
- SAT assignments remain in engine state until the next mutation rather than being copied into a
  second model. Assumption positions each receive a decision level, including dummy levels for an
  already-true assumption, so final analysis remains MiniSat-compatible.
- Assumption UNSAT returns a clause of negated failed assumptions and leaves the solver reusable.
  It does not emit a DRAT empty clause; text DRAT certifies global UNSAT only, whether the clauses
  arrived in one batch or between calls.
- `solve_with` takes everything that varies per query in one record and returns what the call
  spent beside its answer, so the state holds no query settings and a caller never diffs
  counters. `solve` keeps its 0.0.1 signature and is the same search with nothing preferred and
  no budget. A record was chosen over positional arguments because assumptions and preferences
  are both `List(I32)` and a swapped pair would type-check.
- `solve_with` calls `Solver.solve` from two places, one for each side of "is anything preferred".
  A program whose only use of the search is one call gets all of it inlined into the caller's own
  function, and through the first client that compiled the same loop about 3% slower: one proof
  run 40 times retired 20.28 G instructions instead of 19.50 G, and the function holding the loop
  had 109 call sites of the out-of-line `makeUnique` check instead of 85. With two calls the
  search stays out of the caller and measures as before. The cause is the optimizer's
  single-caller inlining, not the search, so re-measure before removing the branch.
- Clauses reach the engine in one of two layouts. The CLI passes the parser's list of lists, which
  `add_all` consumes clause by clause as before. The public API passes one flat list in which
  `Core.undef_lit` ends a clause: `add_clauses` flattens while it decodes, and
  `add_clauses_flat` takes that layout from the caller with `0` as the terminator, DIMACS's own
  convention. Literals after the last `0` form a clause instead of an error because the `Error`
  type is closed and 0.0.1 clients spell it out; a missing terminator would have needed a new tag.
  Flattening the parser's output as well would leave one layout, and was measured at 30 ns per
  clause on the canary (251 to 282 ns), so the CLI path keeps its own.

## Validation and benchmark policy

- The brute solver is deliberately an independent prefix-pruned enumeration, not a reuse of CDCL.
  Parsing preserves duplicate and tautological literals; normalization belongs to clause addition
  so model/proof validators still see the original input.
- Correctness regressions retain and check DRAT proofs. Performance runs omit proofs because proof
  size is not bounded by input size; timeout means unsolved only in benchmark mode. The runner owns
  a process group so timing out an adapter also terminates its child solver.
- The compact corpus stopped at 532 MiB with one known-result representative from each of 81 SAT
  Competition 2025 families. The next distinct families expanded to 127–439 MiB each and duplicated
  covered graph, hardware, or crafted loads, so filling the 900 MB budget would reduce headroom
  without useful diversity.
- SATLIB's `dubois100.cnf` has a clause without its terminating zero. Lenient parsers merge it with
  the following clause; CaDiCaL, Kissat, and rocsat all classify that parsed formula as SAT, which is
  the committed expected result.
