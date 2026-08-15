# Track A — CDCL algorithms and data structures

Run this as a research agent. Language-independent; does not depend on Tracks B or C.

---

You are researching the implementation of a CDCL SAT solver. Your reader is an experienced
systems/functional programmer who will port your findings into Roc. Assume they know nothing
about SAT beyond the definition of the problem.

TARGET: a correct, MiniSat-class CDCL solver. Not a competition solver. Optimizations that
cost significant complexity for <2x speedup are out of scope except as a ranked "later" list.
The solver must support both one-shot DIMACS CNF input and incremental solving under
assumptions, and must be able to emit DRAT proofs.

HARD CONSTRAINT ON DATA STRUCTURES — this is measured, not speculative. In Roc, a flat
`List(U32)` of scalars mutated by index is exactly as fast as C (verified: identical loop
time vs `clang -O2`). A nested `List(List(U32))` clones the inner list on *every* append,
making it ~100x slower and quadratic. So every structure you propose must be expressible as
flat integer arrays indexed by offset. Where the classic implementation would use a vector of
vectors — watch lists above all — you must give me the flat alternatives and compare them:
fixed-capacity blocks with compaction, CSR-style regions with periodic rebuild, and an
intrusive linked list threaded through an index array (the pre-vector technique). For each:
memory overhead, cost of append, cost of remove, cost of the periodic rebuild, and how it
interacts with clause database reduction. Say which you would choose and why.

Your output is a reference document the reader will keep open while coding. Prioritize exact
pseudocode and explicit invariants over narrative explanation. Every algorithm you describe
must be stated precisely enough to implement without consulting your sources.

PRODUCE, in this order:

1. BUILD LADDER. An ordered list of milestones from "naive DPLL that solves 20-variable
   problems" to the full target. For each: what it adds, why that ordering, and a concrete
   acceptance check ("should now solve uf50 instances in <1s"). Aim for 6-10 rungs. Be
   opinionated about the order.

2. DATA STRUCTURE CATALOG. For each core structure — clause arena, watched literals and their
   watch lists, the trail, decision level / reason / assignment / phase arrays, the variable
   activity heap — give: purpose; exact flat layout with the index arithmetic spelled out;
   access pattern and rough mutation frequency per propagation; and the complete set of
   invariants it must maintain, including which operations may temporarily violate them.
   Be especially thorough on watched literals: the invariant, what happens on propagation, on
   backtracking, on clause deletion, and why the scheme needs no work on backtrack.

3. ALGORITHM REFERENCE. Language-neutral imperative pseudocode with invariants for: unit
   propagation; conflict analysis producing the first-UIP clause; recursive/self-subsuming
   learned clause minimization; backjumping; restart policy; clause database reduction;
   solving under assumptions including extracting the final conflict over assumptions. State
   the termination and soundness argument for the main loop.

4. HEURISTICS. VSIDS and EVSIDS, VMTF, phase saving, LBD/glue, Luby vs geometric restarts,
   and briefly stable/focused mode switching. For each: what it does, why it works,
   implementation cost, and measured or reported impact. Rank by value per unit of complexity
   for our target.

5. THE TRAP LIST. The mistakes implementers actually make. Off-by-ones, invariant violations
   that only show as wrong answers on large inputs, subtleties in unit clauses at level 0,
   binary clause handling, self-subsumption during analysis, assumption handling, DRAT
   emission points. High value — dig for it in solver source comments, bug trackers, papers on
   verified solvers, and mailing lists, not just tutorials.

6. FORMATS. DIMACS CNF exactly, including the corners: comment lines, a header that disagrees
   with the body, clauses spanning lines, the empty clause, the trailing zero. SAT competition
   output format. DRAT proof format and how to check proofs with drat-trim.

7. API SHAPE. The solver will be both a CLI and a library. Sketch the public interface for
   incremental use (add clause, solve under assumptions, read model, read final conflict) and
   note IPASIR as the de-facto standard to align with.
   One Roc-specific hazard to flag: Roc evaluates pure top-level values at compile time,
   aggressively. A pure `solve : Cnf -> Answer` applied to a literal CNF at the top level
   would run the solver inside the compiler. Note where this could bite and how to avoid it.

8. ANNOTATED BIBLIOGRAPHY, ranked by usefulness to us, each with a URL and a sentence on what
   it uniquely offers.

KNOWN STARTING POINTS — verify these exist and are what I claim, then go well beyond them; do
not treat this list as the boundary of your search:
  - Een & Sorensson, "An Extensible SAT-solver" (the MiniSat paper) and MiniSat's source
  - Knuth, TAOCP Volume 4 Fascicle 6 "Satisfiability", and his SAT13 implementation
  - Armin Biere's CaDiCaL and Kissat, and their SAT Competition solver descriptions
  - Marques-Silva & Sakallah, GRASP; Moskewicz et al., "Chaff" (origin of VSIDS)
  - Audemard & Simon, "Predicting Learnt Clauses Quality" (LBD)
  - Varisat's internals documentation (a Rust solver with an unusually good writeup)
  - CreuSAT, a formally verified Rust CDCL solver — its proof obligations are a ready-made
    source of explicit invariants, which is exactly what I need
  - The Handbook of Satisfiability, 2nd edition, chapters on CDCL and preprocessing

RULES:
  - Fetch and read primary sources. Do not summarize from memory.
  - Every citation carries a URL you actually retrieved. If you could not retrieve it, label
    it UNVERIFIED and say what you were unable to confirm.
  - Where sources disagree or where you are extrapolating, say so explicitly in line. I would
    rather have "sources differ on X" than a confident synthesis that is wrong.
  - Do not discuss Roc syntax. Track B covers the language.
  - Density beats brevity, but cut anything that doesn't help someone implementing.

Write the document to research/01-cdcl-algorithms.md.
