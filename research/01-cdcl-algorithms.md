# Track A — CDCL algorithms and data structures: an implementer's reference

Status of sources: every URL below was fetched during this research (2026-08-15) unless
marked UNVERIFIED. Where the text says "MiniSat" without qualification it means the git
`master` of `niklasso/minisat` (post-2.2.0); where it says "MiniSat 2.2.0" it means the
released tarball. Where sources disagree, or where I extrapolate, it is flagged inline.

Conventions used throughout (language-neutral, all structures are flat integer arrays):

```
n            number of variables, variables are 0..n-1
lit          literal = 2*var + sign        (sign 0 = positive, 1 = negative)  -- MiniSat/Kissat/Knuth encoding
neg(l)       = l XOR 1                     var(l) = l >> 1
DIMACS d     -> var = |d|-1, sign = (d < 0); back: (var+1) * (sign ? -1 : +1)
value[l]     per-LITERAL value array of size 2n: UNDEF=0, TRUE=1, FALSE=2 (value[neg l] is the dual)
NONE         sentinel for "no reason" / "no clause" (use 0 and reserve arena[0], or U32 max)
```

---------------------------------------------------------------------------------------------

## 1. BUILD LADDER

Ordered, opinionated. Each rung is a *shippable* solver; each acceptance check is something you
can run in CI. Instance families uf20-91 … uf250-1065 / uuf* are the SATLIB random 3-SAT sets
(from memory: 20..250 variables at ratio ~4.26; SATLIB site not fetched — UNVERIFIED that it is
still hosted; the names are stable in the literature). "MiniSat time" below refers to a
Core-i-class laptop, `-O2`; a factor of 2–3 slower is fine at each rung.

| # | Adds | Why here | Acceptance check |
|---|------|----------|------------------|
| 0 | DIMACS parser (§6) + independent *model checker* (evaluate every clause under a full assignment) + a fuzzer that generates random small CNFs and compares against brute force | Everything later is validated by these two tools; the checker is 20 lines and catches 90% of bugs | Parser round-trips a CNF; checker rejects a flipped model; brute-force cross-check on 10 000 random 8-variable CNFs |
| 1 | Naive DPLL, recursive: pick first unassigned var, propagate by scanning *all* clauses to fixpoint, backtrack chronologically | Establishes the value/trail arrays and the "conflict / unit / satisfied" clause classification you will reuse | All 1000 uf20-91 answered SAT with checker-verified models; uuf50-218 (UNSAT) each < 5 s |
| 2 | Iterative search with explicit **trail + trail_lim**, **two watched literals with blocking literal** (§2.3, §3.1), clause **arena** (§2.1), unit clauses handled at level 0 in `add_clause` | 2WL is the single biggest constant-factor win and its invariant shapes everything else (backjumping needs no watch work). Do it before learning so you debug propagation in isolation | uf100-430 (1000 SAT) each < 1 s; uuf100-430 each < 5 s; propagation count identical between rung 1 and rung 2 on the same decision sequence (good differential test) |
| 3 | **CDCL**: 1-UIP conflict analysis, backjumping, learned clause attach with correct second watch, level-0 conflict = UNSAT (§3.2, §3.4) | Turns exponential chronological search into something that solves structured instances at all | uuf250-1065 (100 UNSAT) each < 10 s; pigeonhole `hole8` finishes; every UNSAT answer is later checkable by DRAT (rung 7) |
| 4 | **VSIDS heap** (§2.6, §4.1) + **phase saving** (§4.3) + **Luby restarts** (§4.5) | Decision heuristic is the second biggest win; phase saving is 5 lines; Luby restarts make the run robust. All three are independent of each other | uf250-1065 (100 SAT) each < 1 s (MiniSat: ~0.1–0.5 s); flat200 SAT set each < 1 s; solved-count on a 50-instance mixed industrial set within 2x of MiniSat 2.2 |
| 5 | **Recursive learned-clause minimization** (§3.3), **LBD** computation, **reduceDB** with LBD/used tiers (§3.6, §4.4) | Minimization cuts learned literals ~30% and memory 50% (Sörensson–Biere); reduceDB is required for any long run to bound memory and keep BCP fast | Learned-literal count drops ≥ 25% vs rung 4 on uuf250; a 10-minute run on a hard instance keeps RSS bounded; solved-count improves on the industrial set |
| 6 | **Assumptions + incremental API** (§3.7, §7): `solve(assumptions)`, `final_conflict`, add clauses between calls, IPASIR-shaped surface | Needed by every real user; touches search loop and backjump depth (assumption levels), so do it once the core is stable | An incremental test harness (add clauses one at a time, solve under random assumption sets) agrees with a fresh one-shot solve of (F ∧ assumptions) on 10 000 random cases; failed-assumption sets are genuinely infeasible (re-solve F ∧ core = UNSAT) |
| 7 | **DRAT proof output** (§6.3): units, learned clauses, deletions, empty clause; textual first, binary later | Cheap once emission points are known (§5); a verified proof for every UNSAT instance is the strongest regression test you will ever have | `drat-trim F.cnf F.proof` prints `s VERIFIED` on all uuf* and every UNSAT industrial instance you solve |
| 8 | Level-0 **simplify** (remove satisfied clauses, trim false literals), **arena garbage collection**, watch-pool **defrag/rebuild** (§2.3.4) | Only matters for long runs / incremental use; put last because it is where "wrong answer only on large inputs" bugs live | 30-minute run: arena size stays ≤ 1.2× live bytes; proofs still verify after GC |
| 9+ | "Later" list, ranked by value/complexity for this target (§4.7): (a) binary-clause inline watchers, (b) glue-based EMA restarts + stable/focused switching with reluctant doubling, (c) VMTF in focused mode, (d) trail reuse on restart, (e) saved watch position (Gent), (f) chronological backtracking, (g) preprocessing (BVE, subsumption) | Each is < 2x on average and each costs real complexity | — |

Why this order and not another: (i) propagation before learning, because a wrong `propagate` makes
every later symptom look like a learning bug; (ii) heuristics before minimization/reduce, because
you cannot evaluate reduce policy without VSIDS-shaped clause traffic; (iii) assumptions before
DRAT, because DRAT emission points interact with level-0 handling that assumptions also stress;
(iv) GC last, because until then you can simply never free.

---------------------------------------------------------------------------------------------

## 2. DATA STRUCTURE CATALOG

Everything is a flat `List U32` / `List F64` / `List U8` indexed by arithmetic. Nested lists are
banned by the hard constraint. Sizes: `n` vars, `L = 2n` literals, `m` clauses.

### 2.1 Clause arena

Purpose: store all clauses of length ≥ 2 contiguously; a clause is identified by its offset
(`cref`). Both MiniSat (`RegionAllocator<uint32_t>`, `CRef` = offset;
https://raw.githubusercontent.com/niklasso/minisat/master/minisat/core/SolverTypes.h),
Kissat (`solver->arena`, `reference` = word offset;
https://raw.githubusercontent.com/arminbiere/kissat/master/src/clause.h) and Knuth's SAT13
(`mem[]`, https://www-cs-faculty.stanford.edu/~knuth/programs/sat13.w) do exactly this. Varisat
too: "there is a single `Vec<LitIdx>` used as a buffer for storing all clauses"
(https://jix.one/refactoring-varisat-2-clause-storage-and-unit-propagation/).

Layout (my recommendation; two header words, no floats):

```
arena[c+0] = header:  bits 0..27 = size k (k >= 2), bit 28 = learnt, bit 29 = deleted, bit 30 = reloc(unused unless moving GC), bit 31 = spare
arena[c+1] = meta:    bits 0..7 = glue (LBD, saturate at 255), bits 8..9 = used (0..3), bits 10..31 = spare (e.g. saved search position 'pos', see Gent)
arena[c+2 .. c+2+k-1] = literals; arena[c+2], arena[c+3] are THE TWO WATCHED literals
next clause starts at c + 2 + k
```

Reserve `arena[0]` (write a dummy word) so `cref = 0` can mean NONE. Kissat also reserves the first
stack slot of its watch vectors for the same reason (`if (EMPTY_STACK (*stack)) PUSH_STACK (*stack, 0);`
in `inlinevector.h`).

MiniSat's actual layout for comparison: 32-bit header `{mark:2, learnt:1, has_extra:1, reloced:1, size:27}`
followed by the literals and, for learnt clauses, one extra 32-bit word holding a `float activity`
(SolverTypes.h lines 142–214). MiniSat 2.2 keeps clause activity floats; I recommend integer glue +
`used` (CaDiCaL `reduce.cpp`, Kissat `reduce.c`) instead so the arena is pure U32.

Access pattern: per visited watcher whose blocker is not true, read `arena[c]`, `arena[c+2]`,
`arena[c+3]`; if the clause is not satisfied by the other watch, scan `arena[c+4..]` and write two
words (swap literals). Mutation frequency: one 2-word write per successful watch replacement
(roughly 30–40% of clause visits, PicoSAT reports "the 'other' literal was true in on average 61%
of the visited clauses during BCP", https://cca.informatik.uni-freiburg.de/papers/Biere-JSAT08.pdf).

Invariants:
- A1. `arena[c+2]`, `arena[c+3]` are exactly the two watched literals of clause `c` and appear in
  the watch lists of `neg(arena[c+2])` and `neg(arena[c+3])` (unless the clause is `deleted`).
- A2. No duplicate literals, no complementary pair, in any live clause (enforced at `add_clause`).
- A3. If clause `c` is the reason of literal `p` (`reason[var p] == c`) then `arena[c+2] == p`,
  `value[p] == TRUE`, and every other literal of `c` is FALSE and was assigned no later than `p`
  (CreuSAT's `clause_post_with_regards_to`: `c[0]` satisfied, `c[1..]` all unsat;
  https://github.com/sarsko/CreuSAT `CreuSAT/src/logic/logic_trail.rs`; Knuth: "If c is the current
  reason for literal l, its first literal mem[c].lit is always equal to l").
- A4. `deleted` clauses are never dereferenced by analysis: reduce never deletes a reason clause
  (MiniSat `locked(c)`), and simplify clears `reason` of a level-0 literal before deleting its
  reason (MiniSat `removeClause`: `if (locked(c)) vardata[var(c[0])].reason = CRef_Undef;`).
- Temporarily violated: A1 inside `propagate` between "swap `arena[c+3]` with a new literal" and
  "push the new watcher" (must be re-established before the next clause is visited); A3 inside
  `propagate` before `enqueue` (we set `arena[c+2]` first, then enqueue).

Deletion = set `deleted` bit; memory is reclaimed only by a compacting GC (MiniSat
`garbageCollect/relocAll`, Varisat "Clauses are never deleted from the buffer, they are just marked
as deleted ... creating a new allocator which uses a new buffer and then copying just the
non-deleted clauses"). Trigger: wasted words > 20% of arena (MiniSat `garbage_frac` 0.20). During
compaction you must rewrite (i) `reason[]` of every trail literal whose reason is a live clause,
(ii) `learnts[]`/`clauses[]` lists, (iii) every watch entry — or simply rebuild all watch lists
from the new arena (§2.3.4).

### 2.2 Binary clauses

MiniSat 2.2 keeps binaries in the arena like everything else. Kissat and CaDiCaL store the *other*
literal directly in the watcher and never touch the arena for binary propagation (CaDiCaL
`propagate.cpp`: "Binary clauses are treated separately since they do not require to access the
clause at all"; Kissat `watch.h` tags watchers with a `binary` bit; Varisat keeps "a `Vec<Lit>` per
literal" of binary implications). Recommended for rung 9(a), not before: with a 2-word watcher
`[blocker, cref]` you can encode a binary clause as `[other_lit, BINARY_TAG]` at zero cost later.
Until then, binaries live in the arena; the blocker on a binary watcher *is* the other literal, so
the "blocker true → skip" fast path already avoids the arena access whenever the clause is
satisfied.

### 2.3 Watch lists (the hard part)

Semantics (MiniSat `attachClause`): `watches[neg(c[0])]` gets entry `(cref=c, blocker=c[1])`,
`watches[neg(c[1])]` gets `(cref=c, blocker=c[0])`. I.e. the list is indexed by the literal *whose
becoming TRUE falsifies the watch*; `propagate(p)` walks `watches[p]`.

Watcher entry = 2 U32 words: `w0 = blocker literal`, `w1 = cref`. (MiniSat `Watcher{cref, blocker}`;
CaDiCaL adds a `size` field to recognise binaries; Kissat uses 1 word for binary and 2 for large.)
Fixed 2-word entries keep swap-remove trivial; use `w1 == BINARY_TAG` later if you inline binaries.

Invariant W (the two-watched-literal invariant, stated so it survives backtracking):

> For every live clause `c` with watched literals `a = arena[c+2]`, `b = arena[c+3]`, at any moment
> when the propagation queue is empty (`qhead == len trail`) and no conflict is pending:
>   value[a] != FALSE and value[b] != FALSE,
>   OR one of a, b is TRUE and was assigned at a level ≤ the level of the other (false) one,
>   OR the clause is falsified/unit and this was reported (conflict / enqueue) — impossible when the queue is empty.
> Blocker rule: the blocker of a watcher is *some* literal of `c` (any); "blocker TRUE" ⇒ clause satisfied.

Chaff states the core of it: "It is invariant that in any state where a clause can become newly
implied, both watched literals are not assigned to 0. A key benefit of the two literal watching
scheme is that at the time of backtracking, there is no need to modify the watched literals in the
clause database" (Moskewicz et al., https://www.princeton.edu/~chaff/publication/DAC2001v56.pdf).
CaDiCaL `watch.hpp` phrases the stronger version it maintains: "For both watches: if the watched
literal is negatively assigned either it will be propagated in the future or the corresponding
blocking literal is positively assigned and its level is smaller than the level of the watched
literal".

Why no work on backtrack: unassigning literals can only turn FALSE→UNDEF and TRUE→UNDEF. If both
watches were non-false they stay non-false. If a watch `a` was FALSE and `b` TRUE at level
≤ level(a): backtracking to any level ≥ level(b) keeps `b` TRUE (fine); backtracking below
level(b) also unassigns `a` (level(a) ≥ level(b)) so both become UNDEF (fine). This is exactly why
the *learned clause's second watch must be the literal of the highest remaining level* (MiniSat
Fig. 8: "For the propagation to work, the second watch must be put on the literal which will
first be unbound by backtracking") and why `propagate` may keep a false watch when the other watch
is true (Knuth SAT13: "We can continue with wa on the watch list of bar(lt), even though bar(lt) is
false, because this clause will remain satisfied until backtracking makes lt undefined").

What happens on clause deletion: the watcher stays in the list until removed lazily (MiniSat marks
the list dirty — `watches.smudge` — and `lookup` cleans it before use; CaDiCaL/Kissat drop
watchers whose clause is `garbage` when encountered during propagation) or until a full rebuild.
Both are correct because a deleted clause is *implied* by the rest; propagating with it is
logically sound — but it is a DRAT hazard (§5, item D3).

#### 2.3.1 The three flat representations, compared

Let `T` = total watcher entries (≈ 2m + 2·learnts), `L` = 2n literals, `E` = words per entry (2).

**(A) Pooled variable-capacity blocks with relocation + periodic compaction (Kissat "vectors").**
One global `pool : List U32`; per literal `wofs[l]`, `wlen[l]`, `wcap[l]` (Kissat stores only
`offset,size` in `COMPACT` mode and derives capacity from the next slot: free slots are filled with
`INVALID_VECTOR_ELEMENT = 0xFFFFFFFF`, see `kissat_push_vectors` in
https://raw.githubusercontent.com/arminbiere/kissat/master/src/inlinevector.h — an explicit `wcap`
costs 4 bytes/literal and removes that trick's subtlety).
- Append: if `wlen < wcap` write in place, O(1). Else *relocate*: copy the block to the end of the
  pool with doubled capacity (`kissat_enlarge_vector`: `new_vector_size = old ? 2*old : 1`,
  `memcpy` then `memset(old, 0xff)`, `usable += old_size`), amortized O(1).
- Remove: O(1) swap-with-last (order of a watch list is irrelevant), or the in-loop compaction of
  `propagate` (free).
- Compaction: when `usable` (garbage words) exceeds `defraglim` = 75% of pool size and pool >
  `defragsize` = 2^18 words (Kissat `options.h`, `collect.h`), radix-sort live blocks by offset and
  slide them down (`kissat_defrag_vectors`), O(T + L log L). Live memory ≤ 2× (doubling slack)
  plus garbage until defrag.
- Reduce interaction: none required — deleted-clause watchers die lazily. Kissat additionally
  flushes and *rewatches all clauses* after arena compaction (`kissat_sparse_collect` →
  `flush_all_watched_clauses` + `rewatch_clauses`, `collect.c`).
- Memory overhead: `3·L` control words + slack ≤ T·E + garbage.

**(B) CSR regions with periodic rebuild.** `wstart[l]`, `wlen[l]` into `pool`, lists laid out
contiguously by literal, each with a fixed slack `s` after it.
- Append: O(1) while `wlen < slack`; on overflow you must either (i) relocate the block to the pool
  end (which *is* scheme A) or (ii) push to a per-literal overflow chain / a global "overflow"
  buffer scanned as a second list on every visit. (ii) doubles the branch structure of `propagate`.
- Remove: O(1) swap-with-last.
- Rebuild: counting sort over all live clauses, O(T + L), gives perfectly packed lists with fresh
  slack. Must happen at every reduce/GC anyway if you use (ii).
- Reduce interaction: rebuild from the arena after reduce = free removal of dead watchers.
- Verdict: pure CSR is only attractive if you accept a rebuild each time *any* list overflows;
  the natural fix is relocation, i.e. scheme A. Keep the *rebuild pass* (it is the right thing to do
  after reduce/GC) but not the pure-CSR append.

**(C) Intrusive singly-linked lists threaded through the arena** (PicoSAT, Knuth SAT13; the
pre-vector zChaff-era alternative). Each clause carries two link words in its header:
`link0(c) = mem[c-2]`, `link1(c) = mem[c-3]` (Knuth), a per-literal `whead[l]`. Traversal: at
clause `c` on the list of `l`, follow `link0` if `l == mem[c]` else `link1` (PicoSAT: "the link
for the occurrence list of the first watched literal in the clause is stored in the first link
field ... If l matches the first literal, then the pointer to the next clause in which l is
watched is stored in the first link field").
- Append: O(1) push-front (Knuth: `link1(wa)=lmem[l].watch, lmem[l].watch=wa`).
- Remove: O(1) *while traversing* (you hold the predecessor); O(len) otherwise.
- Rebuild: never needed for capacity; Knuth still does "Recompute all the watch lists" during
  purge, O(T).
- Memory: exactly 2 words per clause (vs 4 words per clause for two 2-word watchers) — the
  cheapest.
- Reduce interaction: deleting a clause requires unlinking from two lists → do it in the purge
  sweep that rebuilds everything, not eagerly.
- Cost: no blocking literal without extra header words, so *every* visit dereferences the clause;
  the next pointer lives in the clause header, so traversal is a pointer chase across the arena
  (cache-hostile). Knuth's own assessment (SAT13): "Nowadays the fastest solvers use a more
  complicated mechanism called 'blocking literals', due to Niklas Sörensson, which is faster
  because it is more cache friendly. However, I'm sticking to linked lists, because (1) they
  don't need dynamic storage allocation of sequential arrays; (2) they use fewer memory
  accesses; (3) on modern multithreaded machines they can be implemented so as to avoid the cache
  misses [by prefetch threads]". PicoSAT (2008, before blocking literals were standard) measured
  the list variant faster than stacks overall but noted "flushing the references to garbage
  clauses as in the stack based implementation is much faster than traversing lists ... in the
  former at least three [words] ... one containing the garbage flag, at least one literal to
  determine the correct link field, and the link field", and that "for highly constrained
  benchmarks of a more combinatorial nature with rather few variables, the classical stack based
  implementation turns out to be faster" (Biere-JSAT08).

Summary table (E = 2 words/entry):

| | append | remove | rebuild/compact | memory | reduce/GC interaction | blocking literal |
|-|-|-|-|-|-|-|
| A pooled blocks | O(1) amortized (relocate on overflow) | O(1) swap or in-loop | O(T + L log L), rare (75% garbage) | T·E + slack ≤ T·E + garbage + 3L | none required; lazy drop; optional rewatch after GC | yes |
| B CSR + slack | O(1) until slack exhausted, then relocate (=A) or overflow chain | O(1) swap | O(T + L) counting sort at each reduce | T·E + L·slack + 2L | rebuild is the removal | yes |
| C intrusive list | O(1) push-front | O(1) during traversal, O(len) otherwise | O(T) full relink at purge | 2 words/clause + L heads | unlink in purge sweep | no (needs +2 words/clause) |

#### 2.3.2 Recommendation

**Choose (A)** — Kissat-style pooled blocks in one flat `pool : List U32`, 2-word entries
`[blocker, cref]`, explicit `wofs/wlen/wcap` arrays, capacity doubling by relocation to the pool
end, in-loop compaction inside `propagate`, and a **full rebuild of the pool from the arena after
every `reduce` and every arena GC** (which also serves as defrag). Reasons: (1) it is byte-for-byte
the MiniSat/CaDiCaL/Kissat access pattern — contiguous scan of `[blocker, cref]` pairs with the
blocker check avoiding ~60% of clause dereferences — so all published tuning applies; (2) it is
implemented today as pure integer arrays in Kissat, so there is no unknown; (3) all mutation is
index-based, so the "push into another list while iterating this one" that `propagate` does is
safe: the current list's `wofs` never changes during its own traversal because the new watch goes
to `neg(new_lit)` and `new_lit != neg(p)` (its value is not FALSE while `neg(p)` is FALSE); with
offsets, growth of the underlying `pool` cannot invalidate anything (Kissat only needs its
`delayed` watch stack because non-`COMPACT` builds hold raw pointers `begin/end` that a
`realloc` moves — see `fix_vector_pointers_after_moving_stack` in `vector.c`); (4) rebuild after
reduce is O(T) at a moment where you already touched every learnt clause, and it makes "deleted
clause still propagates" impossible, which is what keeps DRAT emission simple. Scheme (C) is a
fine *first* implementation if you want zero allocation logic (rung 2), but you will replace it at
rung 4 when propagation dominates, so I would not.

#### 2.3.3 Exact layout and operations for (A)

```
pool  : List U32          -- all watcher words; pool[0] reserved (never a valid offset)
wofs  : List U32  (L)     -- word offset of literal l's block in pool (0 = no block yet)
wlen  : List U32  (L)     -- number of ENTRIES currently in the block
wcap  : List U32  (L)     -- capacity in ENTRIES
garbage : U32             -- words in pool that belong to no live block

entry i of literal l:   pool[wofs[l] + 2*i] = blocker,  pool[wofs[l] + 2*i + 1] = cref

push_watch(l, blocker, cref):
    if wlen[l] == wcap[l]:
        newcap = max(4, 2*wcap[l])
        newofs = len(pool)
        append pool with pool[wofs[l] .. wofs[l] + 2*wlen[l]]      -- copy live words
        append pool with 2*(newcap - wlen[l]) zero words             -- reserve
        garbage += 2*wcap[l]
        wofs[l] = newofs ; wcap[l] = newcap
    j = wofs[l] + 2*wlen[l]
    pool[j] = blocker ; pool[j+1] = cref
    wlen[l] += 1

remove_watch_at(l, i):        -- unordered
    last = wlen[l]-1
    pool[wofs[l]+2*i]   = pool[wofs[l]+2*last]
    pool[wofs[l]+2*i+1] = pool[wofs[l]+2*last+1]
    wlen[l] = last

rebuild_watches():            -- after reduce / GC; O(T)
    for all l: wlen[l] = 0 ; wofs[l] = 0 ; wcap[l] = 0        (or: keep wcap, reset wlen, reuse blocks)
    pool = [0] ; garbage = 0
    -- optional two-pass CSR: count per literal first, then assign wofs with slack, then fill.
    for each live clause c (not deleted):
        a = arena[c+2]; b = arena[c+3]
        push_watch(neg a, b, c); push_watch(neg b, a, c)

defrag():                     -- only needed if you skip rebuild for long; Kissat trigger: garbage > 75% of len(pool) and len(pool) > 2^18
    order literals by wofs ascending (radix/sort), slide each live block down to the first free word, update wofs; garbage = 0
```

`rebuild_watches` is valid at any time when no `propagate` traversal is in progress: invariant A1
says the two watched literals are always `arena[c+2], arena[c+3]`, regardless of the current
assignment, and W is a property of the clause positions, not of the list contents. (Kissat's
`rewatch_clauses` additionally sorts the clause's literals so the two "best" ones are watched and
resets `c->searched = 2`; only necessary because it flushed literals.)

Cost accounting: `propagate` visits `wlen[p]` entries per propagated literal; per entry: 1 read of
`value[blocker]`; on miss, 3 arena reads (`header`, `c+2`, `c+3`) and possibly a scan.

### 2.4 Trail, decision levels, reasons, assignment, phase

```
value    : List U8   (L)   UNDEF/TRUE/FALSE per literal   (assign p: value[p]=TRUE, value[neg p]=FALSE)
level    : List U32  (n)   decision level of the variable's assignment (valid only if assigned)
reason   : List U32  (n)   cref of the propagating clause, or NONE (decision / level-0 unit / assumption)
trail    : List U32        assigned literals in assignment order (grows to <= n)
trail_lim: List U32        trail_lim[d] = index in trail of the DECISION literal of level d+1; decision_level = len(trail_lim)
qhead    : U32             trail[qhead..] not yet propagated
phase    : List U8   (n)   saved polarity: sign of the literal the var last had (MiniSat polarity[], init = 1 i.e. negative first)
seen     : List U8   (n)   analysis marks, always all-zero between analyses
trail_pos: List U32  (n)   optional: index in trail (CaDiCaL `var.trail`, used for minimization sort & early abort)
```

Invariants (CreuSAT `Trail::inv`, MiniSat asserts):
- T1. `trail` contains each variable at most once (`lit_is_unique_inner`), and every literal in
  `trail` is TRUE (`trail_entries_are_assigned_inner`); a variable is assigned iff it is on the
  trail.
- T2. `trail_lim` is sorted, each entry ≤ `len trail` (`sorted(decisions)`), and for `d ≥ 1`
  `trail[trail_lim[d-1]]` is the decision literal of level `d` and has `reason == NONE`.
  Level 0 = `trail[0 .. trail_lim[0])` (or the whole trail if no decisions), all with
  `reason` either NONE (input units) or a clause (implied units); MiniSat and CaDiCaL set the
  reason of level-0 literals to NONE at *simplify*, CaDiCaL even at assignment
  (`if (!lit_level) reason = 0;` in `search_assign`) — either way A4 must hold.
- T3. `level[var(trail[i])]` is non-decreasing in `i`; `level = decision_level` at push time.
- T4. Reason clause of `trail[i]` contains only variables at positions `< i` besides its own
  (CreuSAT `lit_not_in_less_inner`: no literal on the trail occurs in the reason clause of an
  earlier trail entry). This is what makes "walk the trail backwards" a topological order.
- T5. `qhead ≤ len trail`; `qhead == len trail` ⇔ propagation queue empty ⇔ (with W) no clause
  is unit or falsified.
- Temporarily violated: T5 during `propagate` (by design); T1 never; T3/T4 never; W between a
  `cancel_until` and the next `propagate` is fine (see §2.3).

Mutation frequency per propagated literal: 1 trail read; per enqueue: 2 `value` writes, 1
`level`, 1 `reason`, 1 trail append. Per backtrack of a literal: 2 `value` writes, 1 `phase`
write, heap insert.

`cancel_until(lvl)` (MiniSat `cancelUntil`):
```
if decision_level > lvl:
    for i from len(trail)-1 downto trail_lim[lvl]:
        x = var(trail[i])
        phase[x] = sign(trail[i])                 -- phase saving (MiniSat phase_saving==2)
        value[2x] = value[2x+1] = UNDEF           -- reason/level may be left stale: never read while unassigned
        heap_insert_if_absent(x)
    qhead = trail_lim[lvl]
    truncate trail to trail_lim[lvl]
    truncate trail_lim to lvl
```
Note `qhead = trail_lim[lvl]` (MiniSat) — literals at levels ≤ lvl are already propagated.

### 2.5 Clause lists and per-solver scalars

`clauses : List U32` (crefs of irredundant clauses), `learnts : List U32` (crefs of learnt clauses),
`ok : Bool` (false ⇔ level-0 conflict found; MiniSat: "the solver must never be in a conflicting
state" — instead any method that would put it there returns false and sets `ok=false`),
`assumptions : List U32`, `conflict/final : List U32` (negations of failed assumptions),
`model : List U8`, plus counters (`conflicts`, `propagations`, `decisions`, `restarts`).

### 2.6 Variable activity heap (VSIDS)

```
activity : List F64  (n)     -- EVSIDS scores
heap     : List U32          -- variables, binary max-heap by activity
heap_pos : List U32  (n)     -- position in heap, or NOT_IN_HEAP sentinel
var_inc  : F64  = 1.0 ;  var_decay = 0.95
```
MiniSat `Heap` (https://raw.githubusercontent.com/niklasso/minisat/master/minisat/mtl/Heap.h):
`left(i)=2i+1, right(i)=2i+2, parent(i)=(i-1)>>1`; `percolateUp/Down` maintain `indices[]`; the
heap "is a minimum-heap with respect to this comparator" where the comparator is
`activity[x] > activity[y]`, i.e. a max-heap on activity.

Invariants: H1 heap property (`activity[heap[i]] ≥ activity[heap[child]]`; Knuth: "vmem[x].activity
>= vmem[y].activity whenever x=heap[h] and y=heap[2h+1] or y=heap[2h+2]"); H2 `heap_pos[heap[i]] == i`
and `heap_pos[x] == NOT_IN_HEAP` iff x not in heap; H3 (lazy) *every unassigned decision variable is
in the heap* — assigned variables may also be in it, and are skipped at pop (MiniSat `pickBranchLit`:
`while (next == var_Undef || value(next) != l_Undef ...) next = order_heap.removeMin()`; Varisat:
"Assigned variables remain in the heap but are skipped during selection. Backtracking re-inserts
unassigned variables"). H3 is re-established by `cancel_until` (insert every unassigned var) — this
is why `insertVarOrder` is called there.

Bump (MiniSat inline `varBumpActivity`): `activity[v] += var_inc; if activity[v] > 1e100 { for all i:
activity[i] *= 1e-100; var_inc *= 1e-100 }; if in heap: percolate_up(v)`. Decay (`varDecayActivity`):
`var_inc *= 1/var_decay`. CaDiCaL uses limit `1e150` and rescales by the max score
(`rescale_variable_scores`); Kissat uses `MAX_SCORE` and `1/(1-decay)` with `decay = 50` per mille.
Rescaling preserves order, so the heap needs no repair.

Mutation: bumps per conflict = number of variables seen in analysis (dozens to hundreds; the
Biere–Fröhlich paper reports "bumped on average 276 literals per learned clause" for EVSIDS in
Lingeling), each a `log n` percolate; one pop + a few skips per decision.

### 2.7 Learned-clause bookkeeping used by reduce

Per learnt clause (in the arena meta word): `glue` (LBD at learn time, recomputed downward when the
clause is used in analysis — CaDiCaL `bump_clause`: `if (new_glue < c->glue) promote_clause`), `used`
(0..3, set to max when the clause participates in a conflict; decremented at each reduce).
Auxiliary: `levels_seen : List U32` stamp array indexed by level for O(k) LBD computation
(CaDiCaL `gtab`/`recompute_glue`).

---------------------------------------------------------------------------------------------

## 3. ALGORITHM REFERENCE

All pseudocode is imperative and mutates the arrays of §2.

### 3.1 Unit propagation (2WL + blocker)

Source: MiniSat `Solver::propagate` (lines 506–564 of
https://raw.githubusercontent.com/niklasso/minisat/master/minisat/core/Solver.cc); CaDiCaL
`propagate.cpp` for the branch-free "other" trick and saved position; Kissat `proplit.h`.

```
propagate() -> cref | NONE          -- returns conflicting clause, or NONE
    confl = NONE
    while qhead < len(trail):
        p = trail[qhead]; qhead += 1                 -- p is TRUE; visit clauses watching neg(p)
        false_lit = neg(p)
        base = wofs[p]; nw = wlen[p]
        i = 0; j = 0                                 -- read cursor / write cursor (entries)
        while i < nw:
            blocker = pool[base+2i]; c = pool[base+2i+1]; i += 1
            if value[blocker] == TRUE:               -- clause satisfied, keep watcher, don't touch clause
                pool[base+2j] = blocker; pool[base+2j+1] = c; j += 1; continue
            if deleted(arena[c]):  continue          -- (only if you allow lazily dead watchers; drop it)
            -- make sure the false literal is at position c+3
            if arena[c+2] == false_lit: arena[c+2] = arena[c+3]; arena[c+3] = false_lit
            -- (branch-free alternative, CaDiCaL: other = arena[c+2] XOR arena[c+3] XOR false_lit)
            first = arena[c+2]
            if first != blocker and value[first] == TRUE:      -- satisfied by other watch
                pool[base+2j] = first; pool[base+2j+1] = c; j += 1; continue    -- note: blocker updated to `first`
            -- look for a new watch among arena[c+4 .. c+2+size)
            k = c+4; end = c+2+size(arena[c]); found = false
            while k < end:
                if value[arena[k]] != FALSE:
                    arena[c+3] = arena[k]; arena[k] = false_lit
                    push_watch(neg(arena[c+3]), first, c)         -- goes to ANOTHER list (never `p`)
                    found = true; break
                k += 1
            if found: continue                                     -- watcher NOT copied to j: removed from watches[p]
            -- no new watch: clause is unit or conflicting under current assignment
            pool[base+2j] = first; pool[base+2j+1] = c; j += 1     -- keep watcher (false_lit stays watched)
            if value[first] == FALSE:
                confl = c
                qhead = len(trail)                                 -- MiniSat: abort propagation ("queue empty even if conflict")
                copy remaining entries i..nw down to j; j += nw-i; i = nw
            else:
                enqueue(first, c)                                  -- first is UNDEF: unit
        wlen[p] = j
    return confl

enqueue(l, from):     -- MiniSat uncheckedEnqueue
    assert value[l] == UNDEF
    value[l] = TRUE; value[neg l] = FALSE
    level[var l] = decision_level; reason[var l] = from
    push trail l
```

Invariants inside: the write cursor `j ≤ i`; every entry kept is re-validated (blocker true, or other
watch true, or unit/conflict with false watch kept); every entry dropped has been pushed to another
list. If you keep the "propagate the whole queue" MiniSat behaviour (`qhead = len(trail)` on
conflict), then after `propagate` returns, `qhead == len(trail)` always ("Post-conditions: the
propagation queue is empty, even if there was a conflict") — this is what makes the level-0 unit
handling in `add_clause` simple.

Kissat/CaDiCaL refinements (later): saved search position `pos` (Gent JAIR'13: search from the
saved position to the end, then from `c+4` to the saved position; "Replacing the existing
non-optimal implementation of unit propagation in MiniSat speeds up propagation by 29%, though this
is not enough to improve overall run time significantly", https://www.jair.org/index.php/jair/article/view/10839);
binary watchers propagate/conflict without touching the arena; CaDiCaL continues past a binary
conflict to finish binaries then breaks on the first long-clause conflict.

### 3.2 Conflict analysis producing the first-UIP clause

Source: MiniSat `analyze` (Solver.cc 296–384), MiniSat paper Fig. 10, CaDiCaL `analyze()`.
Preconditions (MiniSat comment): `out_learnt` cleared; `decision_level > 0`.
Postconditions: `learnt[0]` is the asserting literal (UIP negated); if `len > 1`, `learnt[1]` has the
greatest level among the rest; `bt_level` = that level, or 0 if the clause is unit.

```
analyze(confl) -> (learnt : List U32, bt_level, glue):
    learnt = [PLACEHOLDER]                    -- slot 0 reserved for the asserting literal
    path_count = 0 ; p = UNDEF ; idx = len(trail)-1
    loop:
        c = confl                              -- assert c != NONE
        bump_clause(c)                         -- glue/used bookkeeping (learnt clauses only)
        for q in literals of c, skipping position 0 when p != UNDEF:     -- c+2 == p for reason clauses (A3)
            v = var q
            if seen[v] == 0 and level[v] > 0:                        -- level-0 literals are dropped: they are false forever
                seen[v] = 1; bump_var(v)
                if level[v] == decision_level: path_count += 1
                else: push learnt q
        -- select next literal on the current level to resolve on: walk trail backwards
        while seen[var(trail[idx])] == 0: idx -= 1
        p = trail[idx]; idx -= 1
        confl = reason[var p]; seen[var p] = 0; path_count -= 1
        if path_count == 0: break
    learnt[0] = neg(p)                          -- p is the first UIP
    (minimize learnt, §3.3; keep seen[] of remaining literals set until then)
    glue = number of distinct levels among learnt (stamp array)
    if len(learnt) == 1: bt_level = 0
    else:
        find i>=1 maximizing level[var(learnt[i])]; swap learnt[1] <-> learnt[i]
        bt_level = level[var(learnt[1])]
    clear seen[] for every literal touched (keep a to-clear list)
```
Why it is the first UIP: `path_count` counts literals of the current level that are seen but whose
reason has not been expanded; walking the trail backwards expands them in reverse assignment order
(a topological order by T4); the first time only one remains, it dominates all paths from the
decision to the conflict (CaDiCaL comment: "This is sound because the topological order in which
literals are processed follows the assignment order and a more complex algorithm to find
articulation points is not necessary"). Each step is a resolution of the current clause with the
reason clause of `p` on variable `p` (Varisat: "equivalent to a resolution of the current clause with
the reason clause of an assignment falsifying a literal"), so the learnt clause is implied by the
DB. Note the last-selected `p` at loop exit has `seen[var p]` already cleared while `confl` of `p`
is *not* expanded — that literal (negated) becomes `learnt[0]`.

Corner: if `p == UNDEF` on the first iteration, iterate over *all* literals of the conflict clause
(there is no implied literal at position 0). If `decision_level == 0` when a conflict occurs: do not
call `analyze`; the formula is UNSAT (MiniSat `search`: `if (decisionLevel() == 0) return l_False;`).

Learn + backjump (MiniSat `search`, CONFLICT branch):
```
    cancel_until(bt_level)
    if len(learnt) == 1: enqueue(learnt[0], NONE)                 -- unit at level 0; emit DRAT "l 0"
    else: c = alloc(learnt, learnt=true, glue); push learnts c; attach(c); enqueue(learnt[0], c); emit DRAT
    var_decay(); (clause decay if using activities)
```
`attach(c)` pushes `(blocker=learnt[1], c)` on `watches[neg learnt[0]]` and `(blocker=learnt[0], c)` on
`watches[neg learnt[1]]`. After `cancel_until(bt_level)`, `learnt[1..]` are all FALSE and `learnt[0]`
UNDEF, so the clause is unit ("asserting") — this is what forces progress.

### 3.3 Learned clause minimization (recursive / self-subsuming)

Local ("basic", MiniSat `ccmin_mode==1`): drop `learnt[i]` if it has a reason and *every* other
literal of that reason is either level-0 or already `seen` (i.e. in the clause). Sörensson–Biere
"local minimization ... resolving out a literal, which has other literals in its antecedent already
in the 1-UIP clause" (https://cca.informatik.uni-freiburg.de/papers/SoerenssonBiere-SAT09.pdf).

Recursive ("deep", MiniSat `ccmin_mode==2`, default): a literal is redundant if a DFS through reason
clauses from it terminates only at seen literals or level-0 literals, never at a decision or at a
literal whose level does not occur in the clause. Knuth: "The literal ā is redundant in the
clause-to-be-learned if and only if the other literals in its reason are either present in that
clause or (recursively) redundant" and "a literal at level 0 is always redundant". Same paper reports:
"The number of solved instances increases by roughly 10% for recursive minimization, and half that
much for local minimization only ... Half of the memory can be saved using recursive minimization".

MiniSat 2.2.0 iterative version with level abstraction (git tag not fetchable; text from the 2.2.0
tarball http://minisat.se/downloads/minisat-2.2.0.tar.gz, `Solver::litRedundant`):
```
abstract_level(v) = 1 << (level[v] & 31)
abstract_levels = OR of abstract_level(var l) for l in learnt[1..]        -- over-approx of the set of levels present

lit_redundant(p, abstract_levels) -> Bool:
    stack = [p]; top = len(to_clear)
    while stack not empty:
        c = reason[var(pop stack)]                     -- assert != NONE
        for q in c[1..]:                               -- skip c[0] == the implied literal
            v = var q
            if seen[v] == 0 and level[v] > 0:
                if reason[v] != NONE and (abstract_level(v) & abstract_levels) != 0:
                    seen[v] = 1; push stack q; push to_clear q
                else:
                    for j in top..len(to_clear): seen[var(to_clear[j])] = 0     -- undo marks of this failed attempt
                    truncate to_clear to top
                    return false
    return true

minimize: for i in 1..len(learnt): keep learnt[i] iff reason[var]==NONE or not lit_redundant(learnt[i], abstract_levels)
```
The current git master replaces the bitmask by a 4-state `seen` (`seen_source=1` = in clause,
`seen_removable=2`, `seen_failed=3`, Van Gelder's "poison") with an explicit `(i, p)` stack, caching
both successes and failures across candidates (Solver.cc lines 388–444). CaDiCaL (`minimize.cpp`) does
it recursively with `poison`/`removable` flags, a hard depth limit `minimizedepth = 1000`, and two
extra pruning rules: "Don Knuth's idea to abort minimization if only one literal was seen on the
level" (`if (!depth && l.seen.count < 2) return false`) and "a new idea of also aborting if the
earliest seen literal was assigned afterwards" (`if (v.trail <= l.seen.trail) return false`); it
sorts the clause by trail position first ("Sorting the clause before minimization with respect to
the trail order ... is necessary but natural"). Recommendation: implement the MiniSat 2.2.0 iterative
version first (no recursion, no depth limit needed), add the 4-state cache when profiling says so.

Invariants: `seen[]` must be all-zero after analysis; only literals with a reason are candidates;
level-0 literals never enter the clause; the asserting literal `learnt[0]` is never removed.
Soundness: each removal is a sequence of self-subsuming resolutions with reason clauses (paper:
"Soundness can be proven by simulating graph traversal with resolution"), so the minimized clause is
still implied and, being RUP, DRAT-checkable as a single addition (Varisat: every learned clause "is
an asymmetric tautology").

### 3.4 Backjumping

Covered by `analyze` + `cancel_until(bt_level)` above. Properties: (i) `bt_level` is the highest level
among `learnt[1..]` (second-highest level in the clause), so after backjump the clause is unit and
`learnt[0]` is enqueued at `bt_level` with reason = the new clause; (ii) MiniSat paper: "This is the
lowest decision level for which the conflict clause is unit"; (iii) all levels above `bt_level` are
discarded, no watch maintenance is required (§2.3). Chronological backtracking (CaDiCaL/Kissat
`chrono`, "SAT'18 paper") is deliberately out of scope: it breaks T3 (assignment level ≠ decision
level) and requires `find_conflict_level` and reason-position repairs (CaDiCaL `analyze()` lines
1043–1101).

### 3.5 Restart policy (Luby; EMA in §4.5)

MiniSat `solve_`: `rest_base = luby_restart ? luby(restart_inc, curr_restarts) : pow(restart_inc,
curr_restarts); status = search(rest_base * restart_first)` with `restart_first = 100`,
`restart_inc = 2`, `luby_restart = true`. `search(nof_conflicts)` returns UNDEF when `conflictC >=
nof_conflicts` after `cancel_until(0)`.

```
luby(y, x):                      -- MiniSat static double luby(double y, int x); sequence 1,1,2,1,1,2,4,1,1,2,1,1,2,4,8,...
    size = 1; seq = 0
    while size < x+1: seq += 1; size = 2*size + 1
    while size-1 != x:
        size = (size-1) >> 1; seq -= 1; x = x mod size
    return y^seq
restart k (k = 0,1,2,...) allows luby(2, k) * 100 conflicts
```
Restart = `cancel_until(0)` (assumptions are re-decided by the search loop). Optionally reuse the
trail (van der Tak et al.; CaDiCaL `reuse_trail`: keep levels whose decision variable outranks the
next decision candidate).

### 3.6 Clause database reduction

MiniSat (activity-based; Solver.cc 575–598): trigger `learnts.size() - nAssigns() >= max_learnts`
where `max_learnts = nClauses()/3` initially and `*= 1.1` every `learntsize_adjust_confl` conflicts
(100, then `*1.5`); sort learnts by activity (binaries first as "most valuable"); "Don't delete
binary or locked clauses. From the rest, delete clauses from the first half and clauses with
activity smaller than 'extra_lim'" (`extra_lim = cla_inc / learnts.size()`).

Recommended (glue tiers, integer only; CaDiCaL `reduce.cpp` and Kissat `reduce.c` agree on the
shape):
```
reduce():                                   -- called at level 0 or any level; never delete reasons
    candidates = []
    for c in learnts:
        if deleted(c): continue
        u = used(c); if u > 0: set used(c) = u-1
        if is_reason(c): continue                                  -- MiniSat locked(c): value[c[0]]==TRUE and reason[var c[0]]==c
        if glue(c) <= tier1 (=2) and u > 0: continue               -- keep glue<=2 forever while used
        if glue(c) <= tier2 (=6) and u >= MAX_USED-1: continue     -- CaDiCaL: `used >= max_used - 1`
        push candidates c
    sort candidates by (glue desc, size desc)                       -- "Clauses of larger glue or larger size are considered less useful"
    delete the first target = 75% (CaDiCaL reducetarget) — or 50% (MiniSat, Glucose) — of candidates: mark deleted, emit DRAT 'd'
    compact learnts; rebuild_watches(); maybe garbage_collect_arena()
    next reduce at conflicts + interval;  MiniSat-style geometric growth of the limit, or CaDiCaL: delta = reduceint(25) * sqrt(conflicts) [reduceopt=1]
```
Glucose's original schedule: "we remove half of the learnt clauses (asserting clauses are kept)
every 20000 + 500 × x conflicts (x is the number of times this action was previously performed)"
(https://www.ijcai.org/Proceedings/09/Papers/074.pdf). Varisat's tiers: "Core (glue ≤2, kept
indefinitely), Mid (glue 3-6), Local (glue >6). Half of Local-tier clauses are removed every 15,000
conflicts" (https://jix.one/refactoring-varisat-4-heuristics/). Kissat's `reduce.c` ranks by
`(~size) | (~glue << 32)` and reduces `reducehigh`→`reducelow` fraction (90%→50%) over time. Sources
differ on exact fractions/intervals; any of these is fine at our target.

Level-0 simplification (MiniSat `simplify`, only at level 0 with empty queue): remove clauses
satisfied at level 0 (`removeSatisfied`), trim false literals at positions ≥ 2 (never touch the two
watches, which are UNDEF at level 0 by W), rebuild the heap. Guard: only if new level-0 assignments
happened since last time (`simpDB_assigns`) and enough propagations passed (`simpDB_props`).

### 3.7 Solving under assumptions and the final conflict

MiniSat `search`: before picking a decision, while `decision_level < len(assumptions)`:
```
    p = assumptions[decision_level]
    if value[p] == TRUE:  new_decision_level()                       -- dummy level, keeps "assumption i lives at level i+1"
    elif value[p] == FALSE: analyze_final(neg p, conflict); return UNSAT_UNDER_ASSUMPTIONS
    else: next = p; break
    then: new_decision_level(); enqueue(next, NONE)
```
The learned-clause backjump may go below the assumption levels; that is fine — the loop above
re-decides them. Restarts cancel to 0 for the same reason. `solve_` ends with `cancel_until(0)`; if
UNSAT and `conflict` is empty then `ok = false` (a real level-0 refutation), otherwise the solver
stays usable and the answer means "UNSAT under these assumptions" (paper §2: "the solver is returned
to a usable state, even when solve() return False, which now should be interpreted as unsatisfiable
under assumptions"). Precondition from the paper: level-0 propagation must be complete before
assumptions are pushed, else "a top-level conflict ... cannot be distinguished from a conflict under
assumptions".

`analyze_final(p)` — "express the final conflict in terms of assumptions. Calculates the (possibly
empty) set of assumptions that led to the assignment of 'p'" (Solver.cc 456–483):
```
analyze_final(p) -> out (a clause over negated assumptions):
    out = [p]                                    -- p is neg(failed assumption); it is FALSE now
    if decision_level == 0: return out           -- failed at level 0: core is just {p}
    seen[var p] = 1
    for i from len(trail)-1 downto trail_lim[0]:            -- everything above level 0
        x = var(trail[i])
        if seen[x]:
            if reason[x] == NONE: push out neg(trail[i])    -- a decision above level 0 = an assumption (or dummy? no: dummy levels have no decision literal)
            else: for q in reason[x][1..]: if level[var q] > 0: seen[var q] = 1
            seen[x] = 0
    seen[var p] = 0
```
Result semantics: `out` is a clause C ⊆ {¬a | a assumption} such that F ⊨ C, i.e. the assumptions
in `out` (negated) are a conflicting subset. IPASIR's `ipasir_failed(a)` ⇔ `neg(a) ∈ out`. Note the
`reason[x] == NONE` test at level > 0 identifies decisions, and every decision at levels 1..k *is* an
assumption (or the dummy-level case, which pushes no literal). CaDiCaL's `failing()` distinguishes
"(1) An assumption is falsified on the root-level ..., (2) two clashing assumptions ..., or (3) a
failing assumption 'first_failed' with minimum (non-zero) decision level" and DFSes from there
(`assume.cpp`); result is the same set semantics.

Incremental adds between solves: `add_clause` at level 0 (call `cancel_until(0)` first); learnt
clauses stay valid because clauses are only ever added (Varisat post 5). If `ok == false`, everything
returns UNSAT immediately.

### 3.8 Main loop, termination and soundness

```
solve(assumptions):
    if not ok: return UNSAT (final = [])
    curr_restarts = 0
    loop:
        r = search(luby(2, curr_restarts) * 100)
        if r != UNDEF: break
        curr_restarts += 1
    if r == SAT: model[v] = value[2v] for all v         -- unassigned (non-decision) vars: choose any
    cancel_until(0); return r

search(nof_conflicts):
    conflictC = 0
    loop:
        confl = propagate()
        if confl != NONE:
            conflicts += 1; conflictC += 1
            if decision_level == 0: (emit DRAT "0"); ok = false; return UNSAT
            (learnt, bt, glue) = analyze(confl); cancel_until(bt); learn+enqueue as in §3.2; decay
        else:
            if conflictC >= nof_conflicts: cancel_until(0); return UNDEF                        -- restart
            if decision_level == 0 and not simplify(): return UNSAT
            if should_reduce(): reduce()
            next = pick assumption per §3.7 (may return UNSAT_UNDER_ASSUMPTIONS)
            if next == UNDEF: next = pick_branch_lit();  if next == UNDEF: return SAT
            new_decision_level(); enqueue(next, NONE)
```
Soundness of UNSAT: every learnt clause is a resolvent of clauses already in the DB (Handbook ch. 4:
"each learnt clause can be inferred from the original clauses and other learnt clauses by a sequence
of resolution steps ... ϕ is satisfiable if and only if ϕ ∪ {ωL} is also satisfiable",
https://www.cs.princeton.edu/~zkincaid/courses/fall18/readings/SATHandbook-CDCL.pdf); a level-0
conflict means the empty clause is derivable. DRAT (§6.3) makes this checkable.
Soundness of SAT: `pick_branch_lit == UNDEF` ⇒ all decision variables assigned; `propagate` returned
NONE with an empty queue ⇒ by W every clause has a non-false watch or a true watch; all variables
assigned ⇒ "non-false" = TRUE ⇒ every clause satisfied. (Handbook: "in modern SAT solvers that use
lazy data structures, clause state cannot be maintained accurately, and so the termination criterion
must be whether all variables are assigned".) Always run the independent model checker in debug
builds.
Termination: without restarts and deletion, each conflict adds an asserting clause that was not
unit-propagated before at `bt_level` (else the literal would already have been assigned), so the
same partial assignment prefix cannot recur; the number of distinct trails is finite. With Luby
restarts the restart intervals are unbounded, and with a learnt-clause limit that grows
geometrically (MiniSat `learntsize_inc = 1.1`) deletion eventually stops interfering; strictly, CDCL
with unbounded deletion is not guaranteed to terminate — practical solvers accept this (my
extrapolation from the standard argument; the Handbook cites [ZMMM01, Zha03] for completeness of
first-UIP learning). Under assumptions the same holds because assumptions are just forced decisions.

---------------------------------------------------------------------------------------------

## 4. HEURISTICS

Ranked at the end (§4.7). "Cost" = lines and new state; "impact" = what the sources report.

### 4.1 VSIDS and EVSIDS
Chaff's original: "(1) Each variable in each polarity has a counter, initialized to 0. (2) When a
clause is added to the database, the counter associated with each literal in the clause is
incremented. (3) The (unassigned) variable and polarity with the highest counter is chosen at each
decision. (4) Ties are broken randomly ... (5) Periodically, all the counters are divided by a
constant" (Chaff DAC'01). EVSIDS = MiniSat's variant: per *variable*, bump every variable *seen*
during analysis (not just those in the learnt clause — MiniSat bumps in the analysis loop) by
`var_inc`, then `var_inc /= 0.95` after each conflict (paper Fig. 14; "Instead of actually
multiplying all variables by a decay factor after each conflict, we bump variables with larger and
larger numbers"). Rescale at 1e100. Biere–Fröhlich: "EVSIDS, VMTF, ACIDS behave very similarly, if
implemented carefully" (https://cca.informatik.uni-freiburg.de/papers/BiereFroehlich-SAT15.pdf); the
same paper documents the lazy heap ("remove variables with maximum score from the priority queue
until the removed variable turns out to be unassigned ... during backtracking, this lazy scheme
still requires to insert variables back") and, in a footnote, a decay ramp used by some MiniSat
descendants: "every 5000th conflict, f is increased by 0.01, starting at 0.8 until 0.95 is reached"
(which solver the footnote refers to is not clear from the extracted text — treat as optional).
Cost: heap + activity array (§2.6), ~80 lines. Impact: essential; without it nothing structured is
solved.

### 4.2 VMTF
Doubly linked list of variables; bumping = unlink and re-enqueue at head, "two simple constant time
operations"; decision = walk from the `next-search` pointer toward the tail until an unassigned
variable; on unassign, move `next-search` back if the variable is closer to head, using an
`enqueue-time` stamp per variable because "variables bumped at the same conflict all get the same
score" (Biere–Fröhlich §3.1). CaDiCaL: `bump_queue` (`queue.dequeue; queue.enqueue; btab[idx] =
++stats.bumped`) and variables are bumped "in the order they are in the current decision queue"
(sorted by `bumped`). Flat layout: `prev/next : List U32 (n)`, `stamp : List U64`, `head, tail,
next_search`. Cost: similar to a heap, no floats. Impact: equal to EVSIDS per Biere–Fröhlich;
Kissat/CaDiCaL use VMTF in focused mode and EVSIDS in stable mode. For our target: EVSIDS only, VMTF
"later".

### 4.3 Phase saving
`phase[x] = sign(trail[i])` on unassign (MiniSat `cancelUntil`, `phase_saving = 2`); decide `mkLit(v,
phase[v])`; initial phase negative (MiniSat `polarity.insert(v, true)`; Kissat option `phase` =
initial phase 1, `warmup`, `rephase` reset schedules — later). Pipatsrisawat–Darwiche: "Every time
the solver performs a backtrack and erases assignments, each erased assignment is saved in this
array. Now, any time the solver decides to branch on variable v, it uses the saved literal"; on 1251
industrial instances "progress saving solves 21 more instances than MiniSat"
(http://www.cs.toronto.edu/~fbacchus/csc2512/Readings/Pipatsrisawat-Darwiche2007_Chapter_ALightweightComponentCachingSc.pdf).
Cost: one U8 array, 3 lines. Impact: large on satisfiable/industrial; interacts with restarts (the
LBD paper: frequent restarts "especially pays when it is associated to phase savings").

### 4.4 LBD / glue
"Definition 1 (Literals Blocks Distance (LBD)) Given a clause C, and a partition of its literals into
n subsets according to the current assignment, s.t. literals are partitioned w.r.t their decision
level. The LBD of C is exactly n." Glue clauses = LBD 2: "they only contain one variable of the last
decision level (they are FUIP), and, later, this variable will be 'glued' with the block of literals
propagated above" (Audemard–Simon 2009). Compute at learn time with a level-stamp array (CaDiCaL:
`glue = levels.size() - 1` collected during analysis; `recompute_glue` on use). Cost: stamp array +
one byte per clause. Impact: enables aggressive reduce ("Glucose ... is the fastest solver in 68
cases and performs a speed-up on common instances of at least 1.2" vs 2007 winners) and the EMA
restart signal.

### 4.5 Restarts: Luby vs geometric vs glue-EMA
MiniSat: Luby with unit 100 (default) or geometric `100 · 2^k` (`luby=false`). PicoSAT: inner/outer
geometric with factor 1.1 (JSAT'08 §: "increased by 10% after every restart ... The 10% increment
resp. the restart factor of 1.1 has been determined empirically"). Biere–Fröhlich POS'15: "for uniform
restart policies, the optimal interval size ... depends on the satisfiability status ... static-256
was the best performing"; "Luby restarts, did not give an additional benefit"; and the Glucose scheme
formalised as EMAs "significantly outperforms all versions with static restart schemes"
(https://cca.informatik.uni-freiburg.de/papers/BiereFroehlich-POS15.pdf). Their recipe: fast EMA of
glue with α_f = 2^-5, slow EMA with α_s = 2^-X (X in 12..18 works), "restart if f > 1.15 · s" after
at least 50 conflicts since the last restart; initialise EMAs with α(i) = 2^-i decreasing to α to
remove start-up bias. CaDiCaL: `emagluefast = 33`, `emaglueslow = 1e5` (window sizes), margin 10%
focused / 25% stable, `restartint = 2`; Kissat: `emafast 33`, `emaslow 1e5`, `restartmargin 10`,
focused restart limit `restartint + log(restarts)`. Cost: Luby = 10 lines; EMA = 2 doubles + 10
lines. Impact: EMA is a clear win on UNSAT/industrial; Luby is robust and simplest. Recommendation:
Luby first, EMA at rung 9.

### 4.6 Stable/focused mode switching (brief)
Idea (Oh, "Between SAT and UNSAT ...", SAT'15 — UNVERIFIED: only the abstract was retrievable via
search): satisfiable instances like long quiet phases with few restarts, unsatisfiable ones like
frequent restarts. CaDiCaL `restart.cpp`: "We start with say 1e3 = 1000 (opts.stabilizeinit)
conflicts of Glucose restarts. Then in a 'stabilizing' phase we disable these ... in the latest
version we still restarts during stabilization but only in a reluctant doubling scheme with a rather
high interval"; phase length grows quadratically in ticks (`next_delta_ticks *= stabphases *
stabphases`), `reluctantint = 1024`, `reluctantmax = 2^20`. Kissat: `modeinit 1e3`, `reluctantint
1<<10`, `reluctantlim 1<<20`, `stable` default on; stable mode uses EVSIDS + reluctant-doubling
(Luby) restarts, focused mode uses VMTF + glue-EMA restarts (`kissat_restarting`). Cost: two
heuristic stacks + a mode flag + separate EMA sets ("swap_averages"). Impact: standard in every
winner since 2018; but it is the most complexity per unit gain on this list — "later".

### 4.7 Ranking by value per unit complexity for our target
1. Two-watched literals with blocking literal (not a heuristic, but the constant factor everything sits on)
2. EVSIDS heap (§4.1)
3. Phase saving (§4.3) — cheapest win
4. First-UIP + recursive minimization (§3.3)
5. LBD + tiered reduce (§4.4, §3.6)
6. Luby restarts (§4.5)
7. Binary-clause inline watchers (§2.2)
8. Glue-EMA restarts (§4.5)
9. Stable/focused switching + reluctant doubling (§4.6)
10. VMTF (§4.2) — only worth it together with 9
11. Trail reuse, saved watch position, chrono backtracking, preprocessing (BVE/subsumption/probing) — out of target

---------------------------------------------------------------------------------------------

## 5. THE TRAP LIST

Grouped; each item says what breaks and how it shows.

### Level 0 and units
- U1. **Level-0 literals must be excluded from learnt clauses** (`level[v] > 0` test in `analyze`
  and in `analyze_final`). Forgetting it yields clauses containing permanently-false literals: still
  sound but LBD/backjump computation is wrong and `bt_level` can be computed as 0 for a non-unit
  clause → you enqueue `learnt[0]` at level 0 with a reason clause that later gets deleted →
  dangling reason.
- U2. **Reason of a level-0 literal may be deleted by `simplify`** (satisfied clause removal): clear
  `reason[]` for level-0 vars (MiniSat `removeClause`: `if (locked(c)) ... reason = CRef_Undef`), or
  never dereference reasons at level 0 (both `analyze` and `analyze_final` skip level 0). Kissat/
  CaDiCaL set the reason to none/`UNIT_REASON` at assignment time. Do one of these *and* assert it.
- U3. **`add_clause` at level 0 must (a) sort/dedupe, (b) drop FALSE literals, (c) return early on
  TRUE literal or complementary pair, (d) enqueue a resulting unit and propagate immediately**
  (MiniSat `addClause_`: `uncheckedEnqueue(ps[0]); return ok = (propagate() == CRef_Undef)`). If you
  defer propagation, a later `add_clause` will evaluate literals against a stale assignment and may
  keep a satisfied clause or, worse, both watches on now-false literals (violates W at level 0).
  Knuth: "Unit clauses in the input might be duplicated or contradictory."
- U4. Empty clause on input or derived: set `ok=false`, emit DRAT `0`. Do not "attach" a size-0/1
  clause: `attach` asserts `size > 1`.
- U5. **`decision_level == 0` conflict inside `search` is UNSAT** — never call `analyze` there
  (MiniSat asserts `decisionLevel() > 0` implicitly: the trail walk `while (!seen[...])` would run
  off the beginning).
- U6. Learned unit: `cancel_until(0)` then `enqueue(l, NONE)` — no clause allocated (MiniSat paper:
  "unit clauses are treated specially, they are never added to the clause database"). Under
  assumptions in the *paper's* old design (root_level > 0) such units were lost between calls; the
  git version backtracks to 0 and re-decides assumptions, which is what you should do.

### Watches and propagation
- W1. **Second watch of the learnt clause = literal of the highest level among the rest.** Otherwise
  W is violated after a later backtrack and a clause can become falsified silently ⇒ wrong SAT.
- W2. **Duplicate literals** ⇒ both watches on the same literal ⇒ propagation misses units. Dedupe
  in `add_clause`; the DRAT/DIMACS grammar also forbids them ("clauses cannot contain duplicate
  literals", drat-trim README).
- W3. `qhead` reset on backtrack to `trail_lim[lvl]` and to `len(trail)` on conflict; forgetting the
  first re-propagates nothing (missed units), forgetting the second lets `propagate` continue after
  a conflict with the pending assignments — MiniSat chose "queue empty even on conflict".
- W4. In the propagation loop the write cursor must copy the *remaining* watchers on conflict (`while
  (i < end) *j++ = *i++`); dropping them loses watches ⇒ wrong SAT later.
- W5. When you push a new watch onto another list while iterating, never cache the pool base of the
  *other* list, and never assume the current list's slice object is still valid if your language
  copies on write — iterate by index over `pool` and re-read `wlen[p]` only at the end.
- W6. Blocker must be a literal of the clause; MiniSat updates it to `first` when it re-inserts the
  watcher, which is why "first != blocker" is checked before re-testing.
- W7. Never move a watch off a literal that is TRUE at a *lower* level than the false watch (the
  W-condition); MiniSat's loop only replaces the *false* watch (`c[1]`), which guarantees this.
- W8. Two watches on a size-2 clause: fine, but binaries must never be trimmed to size 1 in place;
  `remove_satisfied` trims only positions ≥ 2 (asserts `value(c[0]) == l_Undef && value(c[1]) == l_Undef`).
- W9. Kissat's `c->searched`/CaDiCaL `pos` saved position must be reset to 2 whenever the clause is
  rewritten (rewatch, strengthen); an out-of-range saved position reads garbage.
- W10. Rebuild-after-reduce: if you *don't* rebuild and instead drop dead watchers lazily, then a
  binary watcher (which never dereferences its clause) keeps propagating a deleted binary — sound
  for the solver, but see D3.

### Analysis and minimization
- M1. Reason clause literal 0 must be the implied literal (A3). Any code that reorders literals of a
  clause that is currently a reason (simplify trimming, subsumption, on-the-fly strengthening) breaks
  `analyze`'s `j = 1` skip and `lit_redundant`'s `c[1..]` iteration ⇒ the implied literal is
  resolved *into* the clause ⇒ tautological/garbage learnt clauses that fail DRAT.
- M2. `seen[]` must be cleared completely (keep an explicit `to_clear` list; MiniSat asserts
  `seen[released_vars[i]] == 0` in `simplify`). A stale `seen` bit silently changes the next
  learnt clause — the classic "wrong answer only on large inputs".
- M3. `lit_redundant` must undo its marks on failure (MiniSat 2.2: `for (j = top; j < analyze_toclear.size(); j++) seen[...] = 0`)
  or use the 4-state cache; forgetting turns "not proven redundant" into "removable".
- M4. Recursion depth: use an explicit stack or a depth limit (CaDiCaL: 1000, and it explains the
  choice: "The trick to keep potential stack exhausting recursion under guards is to explicitly limit
  the recursion depth").
- M5. `abstract_level` uses `level & 31`: 32-bit over-approximation, collisions are safe (they only
  cause extra work), but a `& 63` with a 32-bit mask is not.
- M6. Bump only variables with `level > 0`; bump before or after minimization is a heuristic choice
  (MiniSat: during analysis, i.e. all seen; CaDiCaL: after minimization, `bump_variables` over
  `analyzed`) — pick one and keep it deterministic.

### Assumptions
- S1. `analyze_final` starts from `neg(p)` where `p` is the *failed assumption* (`value[p]==FALSE`); the
  output is a clause of *negated* assumptions. `failed(a) ⇔ neg(a) ∈ out`. Getting the polarity
  wrong makes every core "empty" or "everything".
- S2. Assumption already TRUE ⇒ open a *dummy* decision level anyway, so `assumptions[decision_level]`
  stays aligned (MiniSat comment "Dummy decision level"). Assumption already FALSE at level 0 ⇒ core
  is `{neg p}` alone (`if (decisionLevel() == 0) return;`).
- S3. Duplicate or complementary assumptions: `a, a` works via the dummy level; `a, ¬a` fails at the
  second with `analyze_final` producing `{¬a... }` — CaDiCaL special-cases "two clashing
  assumptions" (`failed_clashing`) — accept both.
- S4. Do not set `ok=false` on UNSAT-under-assumptions (`if (status == l_False && conflict.size() == 0) ok = false;`).
- S5. Restart/backjump can go below assumption levels; the loop re-decides them — but a *learned
  unit* is enqueued at level 0 with reason NONE, correct even under assumptions.
- S6. `model[]` for variables not decided (e.g. eliminated or non-decision) is UNDEF; IPASIR allows
  `ipasir_val` to return 0 for such literals only if the assignment still satisfies the formula —
  simplest is to give every unassigned variable its saved phase.

### Reduce and GC
- R1. Never delete a reason clause (`locked`); MiniSat's `locked(c)` is `value(c[0]) == l_True &&
  reason(var(c[0])) == cr` — this relies on A3.
- R2. Do not delete binaries in `reduce` (MiniSat) — they are cheap and valuable; if you do (Kissat
  can), see W10/D3.
- R3. During arena compaction, relocate `reason[]` of *trail* literals (MiniSat `relocAll` walks the
  trail: "it is not safe to call 'locked()' on a relocated clause. This is why we keep 'dangling'
  reasons here"), then `learnts`, then `clauses`, then all watchers (or rebuild them).
- R4. Reduce trigger with `learnts.size() - nAssigns()` (MiniSat) approximates the number of locked
  clauses (paper: "the limit is extended by the number of assigned variables, which approximates the
  number of locked clauses").
- R5. Heap must be rebuilt (or every unassigned var re-inserted) after `simplify` at level 0
  (MiniSat `rebuildOrderHeap`) if you remove/release variables.

### DRAT emission points (D)
- D1. Emit each *learnt clause after minimization*, before enqueueing its asserting literal (Glucose:
  `analyze(...); cancelUntil(...); if (certifiedUNSAT) addToDrat(learnt_clause, true);`). Emit
  learnt units as `l 0`.
- D2. Emit *every level-0 forced literal as a unit lemma* (CaDiCaL: `learn_unit_clause` in
  `search_assign` whenever `lit_level == 0`, "root-level unit assign"). It is redundant (RUP) but it
  makes every later deletion of a level-0 reason clause safe (else deleting `(a ∨ ¬b)` after it forced
  `a` removes the checker's only way to derive `a`).
- D3. **Emit `d C` only when C can no longer propagate.** CaDiCaL found by fuzzing that tracing the
  deletion of a *binary* clause when it is marked garbage — while its watchers still propagate —
  produces invalid proofs: "Our strategy to avoid generating incorrect proofs now is to delay tracing
  the deletion of binary clauses marked as garbage until they are really deleted from memory"
  (`propagate.cpp` comment; `delete_clause`/`mark_garbage` in `clause.cpp`). With rebuild-after-reduce
  you can emit `d` at reduce time.
- D4. `add_clause` simplification: if you drop literals or dedupe, emit the *simplified* clause as an
  addition first (it is AT: negating it and unit-propagating the original clause under the level-0
  units yields conflict), then optionally `d` the original (Glucose `addClause_`: `addToDrat(ps,true);
  addToDrat(oc,false)`). Trimming false literals in `simplify` likewise: add trimmed, delete old.
- D5. Emit `0` at the level-0 conflict (both in `add_clause` and in `search`), and only for a
  genuine refutation — never for UNSAT-under-assumptions (Glucose refuses `incremental && certifiedUNSAT`).
- D6. drat-trim "ignores deletion steps of unit clauses by design" and warns; deletions of clauses
  not present are ignored with a warning; "In order to remove all k copies of a clause, k clause
  deletion steps are required". Duplicate clauses in the input therefore need duplicate deletions.
- D7. Binary DRAT: prefix byte `a`(0x61)/`d`(0x64), literals as varint of `2|l| + (l<0)`, terminator
  0x00; do not mix with text; SAT competition expects the file `proof.out`.
- D8. Textual DRAT clauses need not be sorted; the RAT pivot is the *first* literal — irrelevant for
  RUP lemmas, but keep the asserting literal first anyway.

### Format and size traps
- F1. Header disagreeing with body: MiniSat parses whatever is there, growing variables on demand,
  and only complains in strict mode ("DIMACS header mismatch: wrong number of clauses"); CaDiCaL in
  strict mode errors on "too many clauses", "clause missing", "literal %d exceeds maximum variable".
  Decide: be lenient by default (grow `n`), print the number of vars from `max(header, seen)`.
- F2. Clauses span lines; a clause ends only at `0`; a file may end without a final newline; a last
  clause without `0` is an error in CaDiCaL ("last clause without terminating '0'"). Some SATLIB
  files end with a `%` line followed by `0` (from memory — UNVERIFIED): treat `%` as EOF or reject.
- F3. Comment lines start with `c` at line start; MiniSat's parser also skips a stray second `p`
  line by `skipLine`. Whitespace = bytes 9..13 and 32.
- F4. Model output: `v` lines ≤ 4096 chars, terminated by a final `0`; must satisfy every clause
  (partial allowed). Print variables `1..n` from the header even if unused.
- F5. Sizes: literal `2v+1` overflows I32 at v ≥ 2^30; watcher `cref` is a U32 arena offset ⇒ arena
  ≤ 4 G words; `abstract_level` uses 32 bits of levels; LBD saturates at 255; `stamp` counters
  (VMTF/EMA) wrap after 2^32 (Biere–Fröhlich: reassign enqueue-times in a linear scan).
- F6. Kissat `MAX_VECTORS` = 2^32 entries in COMPACT mode ("maximum vector stack size ... exhausted"):
  the pool offset is a U32 — fine below 4 G watcher words; check on push.

---------------------------------------------------------------------------------------------

## 6. FORMATS

### 6.1 DIMACS CNF (as accepted by drat-trim and MiniSat)
Grammar (drat-trim README, https://raw.githubusercontent.com/marijnheule/drat-trim/master/README.md):
```
<formula>   = { <comment> } "p cnf " <var-max> " " <num-cls> "\n" <cnf>
<cnf>       = { <comment> | <clause> }
<comment>   = "c " <anything> "\n"
<clause>    = { <blank> }{ <lit> } "0"
<lit>       = <pos> <blank> | <neg> <blank>
<pos>       = "1" | ... | <max-idx>          (max-idx = 2^31 - 1)
<neg>       = "-" <pos>
<blank>     = " " | "\n" | "\t"
```
"`<var-max>` should be at least as high as the largest `<pos>` used in the formula, while `<num-cls>`
should equal the number of clauses ... the formula is invalid [otherwise]" — that is the strict
reading; MiniSat's `parse_DIMACS_main` is lenient: it reads `p cnf V C`, then repeatedly
`skipWhitespace`; `EOF` → stop; `c` → `skipLine`; otherwise `readClause` (`parseInt` until `0`, `var
= abs(x)-1`, `while (var >= S.nVars()) S.newVar()`), and only if `strictp && cnt != clauses` prints
"PARSE ERROR! DIMACS header mismatch". `parseInt` accepts an optional `+`/`-`, and errors on any
other non-digit ("PARSE ERROR! Unexpected char"). Corner cases:
- comment lines: only recognised at token start (after whitespace); `c` inside a clause is an error.
- header vs body: lenient = grow variable count; report `n = max(header, max var seen)`.
- clauses spanning lines: yes, only `0` terminates.
- the empty clause: a bare `0` ⇒ formula UNSAT (MiniSat `addClause_`: `ps.size() == 0 → ok = false`).
- trailing zero: mandatory; MiniSat would read the next clause's literals into the current clause
  if it is missing — CaDiCaL errors "last clause without terminating '0'".
- Formulas are multisets: duplicate clauses allowed; drat-trim: "no clause can be a tautology" and
  no duplicate literals — real files violate this, so normalise on input (D4).

### 6.2 SAT competition output (https://satcompetition.github.io/2024/output.html)
"All solver output on stdout must either be a comment line, a solution line, or a value line.
Comment lines start with a lower case "c" followed by a space." "The solution line is mandatory and
must appear exactly once ... `s SATISFIABLE` ... `s UNSATISFIABLE` ... `s UNKNOWN`". "Value lines
start with a lower case "v" followed by a space. Values are given as a space-separated list of
non-contradictory literals ... At least one literal of every clause needs to appear in the value
lines. Note that partial satisfying assignments are allowed ... Value lines can have at most 4096
characters ... The last value line must be terminated by a "0"". Proofs: "must be written to a file
called proof.out". Exit codes are a MiniSat convention adopted by IPASIR (`ipasir_solve` returns
10/20/0): MiniSat `Main.cc`: `exit(ret == l_True ? 10 : ret == l_False ? 20 : 0)`
(https://raw.githubusercontent.com/niklasso/minisat/master/minisat/core/Main.cc). Note that the 2024
competition page lists DPR/GRAT/VeriPB checker pipelines; the older text, still present in the page
source inside an HTML comment, says "In case of UNSAT a proof in the DRAT format should be written
into "proof.out"" and describes the binary DRAT format ("we will also support a binary DRAT
format"). For our target: emit text DRAT (and binary optionally) and check with drat-trim.

### 6.3 DRAT and drat-trim
Grammar: `<proof> = { <comment> | <clause> | "d" <blank> <clause> }`. Semantics: "each step in a
clausal proof is either the addition or the deletion of a clause"; a proof "is valid with respect to
a given formula, if 1) all clause addition steps are valid ... and 2) if the proof contains the empty
clause 0"; each added clause must have RAT w.r.t. the current formula with the *first literal as
pivot* (RUP/AT lemmas trivially do; "The empty clause at the end of the proof should have the AT
property"). "Clause deletion steps are ignored if the clause is not present"; unit deletions ignored.
Binary encoding: `map(l) := (l > 0)? 2*l : -2*l + 1`, 7-bit varint little-endian with continuation
MSB, record = `'a'|'d'`, literals, `0x00`; "approximately a factor of three" smaller.
Checking: `./drat-trim F.cnf F.drat` (options: `-f` forward mode, `-p` ignore deletions, `-S`
SAT-check mode, `-t <lim>` seconds, `-c CORE`, `-l LEMMAS`); prints `s VERIFIED` on success, `s NOT
VERIFIED` on failure, `s DERIVATION` when the lemmas check but no empty clause was derived
(https://raw.githubusercontent.com/marijnheule/drat-trim/master/drat-trim.c lines 1480–1483).
Backward checking with core-first propagation is the default.
Example from the README (formula `p cnf 4 8`; proof `-1 0 / d -1 2 4 0 / 2 0 / 0`).

What our solver emits (see D1–D8): every learnt clause (post-minimization); every level-0 unit;
`d` for every reduce/simplify deletion (after rebuild); add-then-delete for strengthened clauses;
final `0`.

---------------------------------------------------------------------------------------------

## 7. API SHAPE

Align with IPASIR (https://raw.githubusercontent.com/biotomas/ipasir/master/ipasir.h), the de-facto
incremental interface (CaDiCaL ships `ipasir.h`, Kissat is not incremental). Its state machine:
INPUT → (solve) → SAT | UNSAT → (add/assume) → INPUT.

| IPASIR | Semantics (quoted) | Our library call |
|---|---|---|
| `ipasir_init` / `ipasir_release` | construct/destroy | `new : {} -> Solver` |
| `ipasir_add(lit_or_zero)` | "Add the given literal into the currently added clause or finalize the clause with a 0. Clauses added this way cannot be removed. The addition of removable clauses can be simulated using activation literals and assumptions." | `add_clause : Solver, List I32 -> Solver` (whole clause at once; also expose the 0-terminated stream form for FFI) |
| `ipasir_assume(lit)` | "Add an assumption for the next SAT search ... After calling ipasir_solve all the previously added assumptions are cleared." | `solve : Solver, List I32 -> (Solver, Result)` takes assumptions explicitly |
| `ipasir_solve` | "returns 10 [SAT] ... 20 [UNSAT] ... 0 [interrupted] ... the state of the solver _during_ execution of 'ipasir_solve' is undefined" | `Result = Sat | Unsat | Unknown` |
| `ipasir_val(lit)` | "Return 'lit' if True, '-lit' if False; ipasir_val(lit) may return '0' if the found assignment is satisfying for both valuations of lit ... Required state: SAT" | `value : Solver, I32 -> [True, False, Undef]`, `model : Solver -> List I32` |
| `ipasir_failed(lit)` | "Check if the given assumption literal was used to prove the unsatisfiability ... The formula remains unsatisfiable even just under assumption literals for which ipasir_failed() returns 1 ... Required state: UNSAT" | `failed : Solver, I32 -> Bool` and `final_conflict : Solver -> List I32` (the negated core, MiniSat `conflict`) |
| `ipasir_set_terminate` / `ipasir_set_learn` | callbacks | budget parameters (`conflict_limit`, `propagation_limit`) instead of callbacks; learn callback later |
| — | | `new_var`, `num_vars`, `set_phase`, `set_proof_output(path, binary)`, `simplify`, `stats` |

Literal encoding at the API boundary: DIMACS signed ints ("They have to be smaller or equal to
INT32_MAX and strictly larger than INT32_MIN"), converted once to internal `2v+sign`.

CLI: `rocsat [options] file.cnf [proof.out]`; prints `c` lines, `s ...`, `v ... 0`; exit 10/20/0;
DIMACS parse errors exit 1 (MiniSat) or 3 (`parseInt` error).

Roc-specific hazard (as instructed, no syntax): Roc evaluates pure top-level values at compile time.
A pure `solve : Cnf -> Answer` applied to a *literal* CNF in a top-level definition (a
demo/benchmark constant, an example in a module, a "golden answer" table, or a top-level
`expected = solve smallCnf`) will run the whole solver inside the compiler — silently slow builds,
or a compiler crash/timeouts on a hard instance. It also bites in tests that build the CNF as a
constant and solve it at top level. Avoid it by (a) obtaining every real CNF through an effect (file
read, args, stdin) so the call is inside the effectful entry point, (b) keeping test CNFs tiny and
solving them inside test bodies rather than as top-level constants, (c) never exposing a top-level
`Solver` value that already contains a solved state. The same applies to `parse` on a large literal
string.

---------------------------------------------------------------------------------------------

## 8. ANNOTATED BIBLIOGRAPHY (ranked by usefulness to us)

1. MiniSat source, `minisat/core/Solver.cc`, `Solver.h`, `SolverTypes.h`, `Heap.h`, `Dimacs.h`, `Main.cc` —
   https://raw.githubusercontent.com/niklasso/minisat/master/minisat/core/Solver.cc (and siblings).
   The reference implementation of every algorithm in §3; the exact code for `propagate`, `analyze`,
   `litRedundant`, `analyzeFinal`, `cancelUntil`, `reduceDB`, `luby`, `search`, garbage collection.
   Read it once end to end.
2. Eén & Sörensson, "An Extensible SAT-solver" (extended version 1.2), http://minisat.se/downloads/MiniSat.pdf.
   The narrative behind (1): watcher lists needing no undo, the API contract (`ok`, assumptions,
   root level), Fig. 8's note on the second watch, Fig. 10 `analyze`, Fig. 15 `reduceDB`, Fig. 16 the
   solve loop with constants (0.95, 0.999, 100 conflicts × 1.5, learnts = clauses/3 × 1.1).
3. Kissat source (`vector.c`, `inlinevector.h`, `watch.h`, `proplit.h`, `collect.c/h`, `reduce.c`,
   `restart.c`, `mode.c`, `options.h`), https://github.com/arminbiere/kissat — the only production
   solver whose watch lists are pure flat integer arrays with an explicit compaction policy
   (`defraglim` 75%, `defragsize` 2^18); also the tier/`used` reduce and stable/focused parameters.
4. CaDiCaL source (`propagate.cpp`, `analyze.cpp`, `minimize.cpp`, `assume.cpp`, `reduce.cpp`,
   `restart.cpp`, `watch.hpp`, `clause.cpp`, `options.hpp`, `ipasir.h`), https://github.com/arminbiere/cadical —
   best-commented C++ CDCL; the DRAT binary-deletion bug story, the invariant statement in `watch.hpp`,
   the minimization pruning rules, `failing()` for assumption cores, EMA restarts and stabilization.
5. Knuth, SAT13 (CWEB), https://www-cs-faculty.stanford.edu/~knuth/programs/sat13.w, and TAOCP 4
   Fascicle 6 preprint (fasc6a, https://www-cs-faculty.stanford.edu/~knuth/fasc6a.ps.gz; Algorithm C
   steps C1–C9, MEM layout with `link0/link1`) — the intrusive linked-list watch representation done
   carefully, plus his stated invariants (reason literal first, level-0 special, "a subtle point,
   actually unknown to the author for many years").
6. Varisat, "Refactoring Varisat" posts 2–5, https://jix.one/refactoring-varisat-2-clause-storage-and-unit-propagation/,
   https://jix.one/refactoring-varisat-3-cdcl/, https://jix.one/refactoring-varisat-4-heuristics/,
   https://jix.one/refactoring-varisat-5-incremental-solving-and-proofs/ — a Rust CDCL described as
   flat buffers with offset references; separate binary implication lists; the LRAT/minimization
   ordering complication.
7. CreuSAT (Skotåm), https://github.com/sarsko/CreuSAT — machine-checked invariants for trail,
   watches, reasons (`logic_trail.rs`, `logic_watches.rs`, `unit_prop.rs` contracts): the exact
   properties T1–T4 and A3, in a form you can turn into debug assertions.
8. drat-trim README, https://raw.githubusercontent.com/marijnheule/drat-trim/master/README.md —
   the normative DIMACS/DRAT grammar, RAT/AT definitions, deletion semantics, binary encoding.
9. IPASIR header, https://raw.githubusercontent.com/biotomas/ipasir/master/ipasir.h — the API
   contract text (states, `val`, `failed`, return codes 10/20/0).
10. Sörensson & Biere, "Minimizing Learned Clauses" (SAT'09), https://cca.informatik.uni-freiburg.de/papers/SoerenssonBiere-SAT09.pdf —
    local vs recursive minimization stated as algorithms, soundness by resolution, +10% solved / 50% memory.
11. Audemard & Simon, "Predicting Learnt Clauses Quality in Modern SAT Solvers" (IJCAI'09),
    https://www.ijcai.org/Proceedings/09/Papers/074.pdf — LBD definition, glue clauses, the
    "20000 + 500x, delete half" schedule.
12. Biere & Fröhlich, "Evaluating CDCL Restart Schemes" (POS'15), https://cca.informatik.uni-freiburg.de/papers/BiereFroehlich-POS15.pdf —
    EMA restart formulation with concrete α, margins, initialisation trick; static vs Luby vs Glucose data.
13. Biere & Fröhlich, "Evaluating CDCL Variable Scoring Schemes" (SAT'15), https://cca.informatik.uni-freiburg.de/papers/BiereFroehlich-SAT15.pdf —
    VMTF queue with `next-search` and enqueue-time stamps; EVSIDS ≈ VMTF ≈ ACIDS.
14. Biere, "PicoSAT Essentials" (JSAT'08), https://cca.informatik.uni-freiburg.de/papers/Biere-JSAT08.pdf —
    intrusive linked-list occurrence lists vs stacks, with measurements and the GC-traversal caveat;
    binary clause special treatment; inner/outer restarts.
15. Moskewicz et al., "Chaff" (DAC'01), https://www.princeton.edu/~chaff/publication/DAC2001v56.pdf —
    origin of 2WL-with-no-backtrack-work and the original VSIDS definition.
16. Pipatsrisawat & Darwiche, "A Lightweight Component Caching Scheme" (SAT'07),
    http://www.cs.toronto.edu/~fbacchus/csc2512/Readings/Pipatsrisawat-Darwiche2007_Chapter_ALightweightComponentCachingSc.pdf —
    phase (progress) saving, +21 instances on 1251 industrial.
17. Marques-Silva, Lynce, Malik, "CDCL SAT Solvers", Handbook of Satisfiability ch. 4 (1st ed. 2008 text),
    https://www.cs.princeton.edu/~zkincaid/courses/fall18/readings/SATHandbook-CDCL.pdf — Algorithm 1,
    soundness/completeness statement, first-UIP discussion. The 2nd edition (2021) chapter was not
    retrieved — UNVERIFIED that its content differs materially.
18. Gent, "Optimal Implementation of Watched Literals and More General Techniques" (JAIR 2013),
    https://www.jair.org/index.php/jair/article/view/10839 — saved-position search, 29% propagation speedup.
19. Glucose source `core/Solver.cc`, https://raw.githubusercontent.com/audemard/glucose/master/core/Solver.cc —
    concrete DRAT emission points in a MiniSat-derived solver (`addToDrat`, binary writer `write_lit`).
20. SAT Competition output format, https://satcompetition.github.io/2024/output.html — `s`/`v`/`c` rules, `proof.out`.
21. Chu, Harwood, Stuckey, "Cache Conscious Data Structures for Boolean Satisfiability Solvers" (JSAT 2009) —
    UNVERIFIED (PDF link returned HTML); abstract via search reports +80% propagation speed on MiniSat 2.0
    from cache-conscious layout; origin of the blocking-literal idea per CaDiCaL's comment.
22. Oh, "Between SAT and UNSAT: The Fundamental Difference in CDCL SAT" (SAT'15) — UNVERIFIED (paywalled);
    motivation for stable/focused phases.
23. Marques-Silva & Sakallah, GRASP (1996); Luby, Sinclair, Zuckerman (1993) — UNVERIFIED (not retrieved);
    cited by (2), (12), (17) as the origins of learning/backjumping and of the restart sequence.
