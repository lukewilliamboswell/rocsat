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

## Phase 1 — solver milestones (Track A rungs)

| # | Milestone | Acceptance | Status |
|---|-----------|------------|--------|
| 0 | Harness: scaffold, DIMACS parser, model checker, brute-force reference, `bench/` (SATLIB, CaDiCaL statuses, run/fuzz scripts), edge-case CNFs, `make check` | `make check` green from a clean clone; brute matches CaDiCaL on uf20 + edge cases; 60 s fuzz clean | [ ] |
| 1 | Naive recursive DPLL (scan-all-clauses propagation, chronological backtrack) | 1000 uf20-91 SAT with checked models; uuf50-218 each < 5 s | [ ] |
| 2 | Iterative search, trail + trail_lim, 2WL with blocking literal, clause arena, level-0 units; propagate CI canary | uf100 < 1 s, uuf100 < 5 s each; propagation count identical to rung 1 on same decisions | [ ] |
| 3 | CDCL: 1-UIP analysis, backjumping, learned-clause attach; text DRAT writer | uuf250 each < 10 s; `hole8` finishes; every UNSAT `drat-trim` verified | [ ] |
| 4 | VSIDS heap, phase saving, Luby restarts | uf250 each < 1 s; flat200 each < 1 s; ≤ 2× MiniSat solved-count on 50 mixed instances | [ ] |
| 5 | Recursive clause minimisation, LBD, reduceDB with tiers; watch-pool rebuild with slack | ≥ 25 % fewer learned literals on uuf250; bounded RSS over 10 min | [ ] |
| 6 | Assumptions + incremental IPASIR-shaped API | 10 000 random incremental cases agree with one-shot solve (PySAT differential); cores genuinely infeasible | [ ] |
| 7 | Binary DRAT, level-0 simplify, arena GC, watch-pool defrag | 30-min run: arena ≤ 1.2× live; proofs still verify | [ ] |
| 8+ | Later list: binary-clause inline watchers, glue-EMA + stable/focused restarts, VMTF, trail reuse, saved watch position, chronological backtracking, preprocessing | each measured on the nightly suite | [ ] |

## Phase 2 — infrastructure (grows alongside)

- [ ] Nightly suite: all SATLIB + 100–200 GBD-selected competition instances, PAR-2 deltas,
      1 h `runcnfuzz`, `hyperfine` min-of-N, RSS (after milestone 2)
- [ ] Upstream reports: record-field-projection spurious incref, nominal-pattern segfault,
      `roc test --opt=speed` link failure, nominal method dispatch cost, monotonic clock in
      basic-cli (see `research/02-roc-performance.md` UNRESOLVED)
- [ ] Simplification passes when `plans/simplify-backlog.md` clusters around one area

## Log

- 2026-08-16 — research complete; step-0 decisions taken; milestone 0 planned.
