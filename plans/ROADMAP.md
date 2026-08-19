# rocsat roadmap

A CDCL SAT solver in Roc (new compiler). This file tracks high-level progress only; per-task
plans live in `plans/YYYY-MM-DD-*.md` (local, gitignored) and the details behind each milestone in
`research/`.

Legend: `[x]` done · `[~]` in progress · `[ ]` not started

## Phase 0 — research (done)

- [x] Vendored Roc docs and notes (`roc-docs/`)
- [x] Performance spikes Q1–Q8 (`spike/RESULTS.md`)
- [x] Track A — CDCL algorithms and milestone ladder (`research/01-cdcl-algorithms.md`)
- [x] Track B — Roc performance and module structure (`research/02-roc-performance.md`)
- [x] Track C — testing and benchmarking method (`research/03-testing-benchmarking.md`)
- [x] Fixed decisions (2026-08-16): basic-cli 0.22.0; `U32` literals `2v+sign`; `List(U32)`
      clause arena; `src/` + `bench/` + `tests/` layout. The compiler is now pinned to
      `nightly-2026-08-18-e9be50a` after a same-host canary and reproducer comparison.

## Phase 1 — solver milestones

Condensed from the Track A rung ladder: the naive-DPLL and chronological-backtrack rungs are
skipped (their code would be thrown away; the harness plus a dev-build propagation-completeness
invariant replaces their differential value), and arena GC / watch rebuild land with reduceDB,
the first place clauses get deleted. The end product is a library with a CLI front end.

| # | Milestone | Acceptance | Status |
|---|-----------|------------|--------|
| 0 | Harness: scaffold, DIMACS parser, model checker, brute-force reference, `bench/` (SATLIB, CaDiCaL statuses, run/fuzz scripts), edge-case CNFs, `make check` | `make check` green from a clean clone; brute matches CaDiCaL on uf20 + edge cases; 60 s fuzz clean | [x] |
| 1 | Core CDCL: clause arena, 2WL with blocking literal, trail + trail_lim, level-0 units, 1-UIP analysis, backjumping, learned-clause attach, text DRAT writer; dev-build invariant "no unit/falsified clause after propagate"; propagate CI canary | uf100 < 1 s, uuf100 < 5 s, uuf250 < 10 s each; `hole8` finishes; every UNSAT `drat-trim` verified; fuzz clean | [x] (uuf250 miss addressed by milestones 2–3) |
| 2 | VSIDS heap, phase saving, Luby restarts | uf250 each < 1 s; flat200 each < 1 s; ≤ 2× MiniSat solved-count on 50 mixed instances | [x] (absolute uf250 target misses; comparison target passes) |
| 3 | Recursive clause minimisation, LBD, reduceDB with tiers, arena GC, watch-pool rebuild with slack, level-0 simplify | ≥ 25 % fewer learned literals on uuf250; 30-min run keeps arena ≤ 1.2× live and RSS bounded; proofs still verify | [x] |
| 4 | Library API: assumptions, incremental clause adding, `final_conflict`, IPASIR-shaped surface; CLI becomes a thin client of it | 10 000 random incremental cases agree with one-shot solve (PySAT differential); cores genuinely infeasible | [x] |
| 5+ | Later list: binary DRAT, binary-clause inline watchers, glue-EMA + stable/focused restarts, VMTF, trail reuse, saved watch position, chronological backtracking, preprocessing | each measured on the nightly suite | [ ] |

## Phase 2 — infrastructure (grows alongside)

- [x] Compact diversity suite: 5,680 hash-pinned CNFs / 532 MiB, including 24 SATLIB/classic
      sets and 81 distinct known-result Competition 2025 families; serial smoke/diversity tiers,
      PAR-2/JSON comparison, solver counters, and Linux RSS
- [ ] Long-running infrastructure: one-hour `runcnfuzz`, repeated min-of-N whole-suite baselines,
      and optional larger competition instances when a compact representative misses a load shape
- [x] Upstream reports: eight verified reproducers in `upstream/`; issues 01, 02, and 05 were
      filed as roc#10848, roc#10847, and roc#10849, and the remaining findings were raised in Roc
      forum discussions/comments. Reporting is closed for this project. Nominal method dispatch
      cost was re-measured and withdrawn; the monotonic clock is a basic-cli request.
- [ ] Simplification passes when `plans/simplify-backlog.md` clusters around one area

## Current handoff (2026-08-19)

- The pinned compiler remains `nightly-2026-08-18-e9be50a`. Keep the list-threaded hot APIs until
  issue roc#10848 is fixed and a canary confirms record threading is safe.
- Milestones 2–4 are complete. `Rocsat` now provides signed literals, dynamic variables,
  incremental clause addition, assumptions, SAT inspection, phase control, and failed-assumption
  conflicts over the existing deterministic EVSIDS/Luby/lifecycle engine. The next solver work is
  selected from milestone 5+; check `plans/simplify-backlog.md` before touching `Core`.
- Serial 1-second SATLIB counts on the final host are rocsat 57/100 uf250, 8/100 uuf250, and
  100/100 flat200, versus MiniSat 82/100, 13/100, and 100/100. The roadmap's absolute all-uf250
  target was unrealistic on this host, but the relative solved-count target passes.
- Reporting upstream is closed. `make check` remains the commit gate and `make canary` is required
  for hot storage or API changes. Use `make perf-smoke` for measured implementation increments and
  `make perf-diverse` before accepting heuristic changes; both tiers are serial and outside CI.

## Log

- 2026-08-16 — research complete; step-0 decisions taken; milestone 0 planned; ladder condensed to 0–4 + later list (library, not only CLI).
- 2026-08-16 — milestone 0 done: parser (349 MB/s), model checker, brute reference, bench harness (run/expected/fuzz/canary), 31 edge CNFs, `make check` in ~34 s.
- 2026-08-16 — milestone 1 done: `rocsat solve` (CDCL, 1-UIP, DRAT). uf100/uuf100 ≤ 0.14 s, hole10 71 ms; all UNSAT proofs verified; uf250/uuf250 do not finish in 7 min with the static decision order (milestone 2 re-measures). Compiler finding: only list-parameter/tuple-return functions and `var`-held lists stay in place on this nightly — record threading copies; shape rules in `src/Core.roc`.
- 2026-08-16 — `upstream/`: eight compiler/toolchain/docs problems re-verified on the pinned nightly and reduced to self-contained reproducers, plus four earlier notes that did not reproduce and one (nominal dispatch cost) that was withdrawn.
- 2026-08-18 — updated to `nightly-2026-08-18-e9be50a` after same-host validation; minimized issues 01, 02, 05, 06, and 07; filed 01, 02, and 05 as roc#10848, roc#10847, and roc#10849.
- 2026-08-19 — milestone 2 complete: deterministic EVSIDS, phase saving, and tuned Luby restarts;
  final serial 1-second counts are 57 uf250, 8 uuf250, and 100 flat200, versus MiniSat 82/13/100.
- 2026-08-19 — milestone 3 complete: recursive minimization removes 27.7% of derived literals on
  the fixed uuf250 sample (44.5% versus a non-minimizing build); tiered reduction, one-sixth-waste
  arena GC, watch rebuilds, and root simplification keep storage bounded with verified DRAT proofs.
- 2026-08-19 — milestone 4 complete: the signed-literal `Rocsat` facade supports dynamic variables,
  clauses between calls, assumptions, models/values, phase control, and final conflicts. A
  10,000-query differential across 1,000 persistent sessions matched fresh PySAT; every SAT model
  and independently re-solved failed core passed.
- 2026-08-19 — compact benchmark infrastructure complete: an atomic SHA-256 fetcher enforces a
  900 MB budget; 81 compact competition families broaden the existing classic corpus to 532 MiB;
  serial smoke/diversity runs distinguish timeouts from invalid answers and report PAR-2, RSS,
  solver counters, and JSON deltas.
