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
- The trail and heap are fixed-capacity indexed buffers with explicit live lengths. The original
  claim that list truncation destroyed uniqueness did not reproduce, but changing these buffers
  would alter the hottest propagation/backtrack storage and therefore remains a separately measured
  simplification, not incidental cleanup.

## Search and learned-clause lifecycle

- Branching is deterministic EVSIDS with lower variable IDs winning equal-activity ties. Full phase
  saving occurs while erasing the backtracked trail suffix. Conflict analysis returns every visited
  variable for activity bumps; minimization does not change that bump set.
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
  It does not emit a DRAT empty clause; text DRAT is reserved for one-shot global UNSAT.

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
