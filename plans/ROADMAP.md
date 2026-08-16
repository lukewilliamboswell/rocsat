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
- [x] Fixed decisions (2026-08-16): basic-cli 0.22.0 on nightly 2026-08-13-2fdd90e; `U32`
      literals `2v+sign`; `List(U32)` clause arena; `src/` + `bench/` + `tests/` layout

## Phase 1 — solver milestones

Condensed from the Track A rung ladder: the naive-DPLL and chronological-backtrack rungs are
skipped (their code would be thrown away; the harness plus a dev-build propagation-completeness
invariant replaces their differential value), and arena GC / watch rebuild land with reduceDB,
the first place clauses get deleted. The end product is a library with a CLI front end.

| # | Milestone | Acceptance | Status |
|---|-----------|------------|--------|
| 0 | Harness: scaffold, DIMACS parser, model checker, brute-force reference, `bench/` (SATLIB, CaDiCaL statuses, run/fuzz scripts), edge-case CNFs, `make check` | `make check` green from a clean clone; brute matches CaDiCaL on uf20 + edge cases; 60 s fuzz clean | [x] |
| 1 | Core CDCL: clause arena, 2WL with blocking literal, trail + trail_lim, level-0 units, 1-UIP analysis, backjumping, learned-clause attach, text DRAT writer; dev-build invariant "no unit/falsified clause after propagate"; propagate CI canary | uf100 < 1 s, uuf100 < 5 s, uuf250 < 10 s each; `hole8` finishes; every UNSAT `drat-trim` verified; fuzz clean | [x] (uuf250 misses: needs milestone 2) |
| 2 | VSIDS heap, phase saving, Luby restarts | uf250 each < 1 s; flat200 each < 1 s; ≤ 2× MiniSat solved-count on 50 mixed instances | [ ] |
| 3 | Recursive clause minimisation, LBD, reduceDB with tiers, arena GC, watch-pool rebuild with slack, level-0 simplify | ≥ 25 % fewer learned literals on uuf250; 30-min run keeps arena ≤ 1.2× live and RSS bounded; proofs still verify | [ ] |
| 4 | Library API: assumptions, incremental clause adding, `final_conflict`, IPASIR-shaped surface; CLI becomes a thin client of it | 10 000 random incremental cases agree with one-shot solve (PySAT differential); cores genuinely infeasible | [ ] |
| 5+ | Later list: binary DRAT, binary-clause inline watchers, glue-EMA + stable/focused restarts, VMTF, trail reuse, saved watch position, chronological backtracking, preprocessing | each measured on the nightly suite | [ ] |

## Phase 2 — infrastructure (grows alongside)

- [ ] Nightly suite: all SATLIB + 100–200 GBD-selected competition instances, PAR-2 deltas,
      1 h `runcnfuzz`, `hyperfine` min-of-N, RSS (after milestone 1)
- [~] Upstream reports: eight verified reproducers and a report in `upstream/` (record-field
      projection clone, nominal-pattern compiler segfault, `roc test --opt=speed` link failure,
      `--opt=interpreter` link failure, nested-list clone, `List.reserve` growth, helper not
      inlined, stale `expect` doc). Nothing filed yet. Nominal method dispatch cost was
      re-measured and withdrawn; the monotonic clock is a basic-cli request, still open.
- [ ] Simplification passes when `plans/simplify-backlog.md` clusters around one area

## Log

- 2026-08-16 — research complete; step-0 decisions taken; milestone 0 planned; ladder condensed to 0–4 + later list (library, not only CLI).
- 2026-08-16 — milestone 0 done: parser (349 MB/s), model checker, brute reference, bench harness (run/expected/fuzz/canary), 31 edge CNFs, `make check` in ~34 s.
- 2026-08-16 — milestone 1 done: `rocsat solve` (CDCL, 1-UIP, DRAT). uf100/uuf100 ≤ 0.14 s, hole10 71 ms; all UNSAT proofs verified; uf250/uuf250 do not finish in 7 min with the static decision order (milestone 2 re-measures). Compiler finding: only list-parameter/tuple-return functions and `var`-held lists stay in place on this nightly — record threading copies; shape rules in `src/Core.roc`.
- 2026-08-16 — `upstream/`: eight compiler/toolchain/docs problems re-verified on the pinned nightly and reduced to self-contained reproducers, plus four earlier notes that did not reproduce and one (nominal dispatch cost) that was withdrawn. Not filed yet.
