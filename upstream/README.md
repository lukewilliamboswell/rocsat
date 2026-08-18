# Roc issues found while building rocsat

Everything here was hit while writing a CDCL SAT solver in Roc, and re-verified on
**`nightly-2026-08-13-2fdd90e`** (release build, arm64 macOS / Darwin 24.6.0) on 2026-08-16
before being written down. Every issue below was re-run on that date; where a note from the
project's earlier spikes did not reproduce, it is listed in [Not reproduced](#not-reproduced)
rather than dropped. The one place older numbers are cited without a fresh run is the 62-shape
survey in issue 01, which is this project's own spike on the same nightly and is marked as such.

Each numbered directory is a self-contained reproducer: a `README.md` written as an issue
draft, plus the Roc files, plus (where the symptom is timing or flakiness) a way to run it.
Every timing MRE prints a checksum so the modes can be compared for equality, and takes its
sizes from `argv` so nothing is constant-folded at compile time.

Filed upstream: [01 as roc#10848](https://github.com/roc-lang/roc/issues/10848) and
[02 as roc#10847](https://github.com/roc-lang/roc/issues/10847). Search for duplicates before
filing the remaining reports.

## Latest-nightly retest

On 2026-08-18 we compared the original compiler with **`nightly-2026-08-18-e9be50a`** on the
same Linux ARM64 host. The solver's 2 M-clause scaling canary was unchanged: 294.2 ns/clause on
`nightly-2026-08-13-2fdd90e` and 292.1 ns/clause on the new nightly, both well below its 700 ns
hard ceiling. The performance shapes that forced the solver's flat, list-threaded design also
remain:

| # | Latest-nightly result |
|---|---|
| [01](01-record-field-clone/) | Reproduced and reduced to one list, one scalar, and one loop. With a 1 M-element list, 100/200/400 writes through a call-built record took 296/597/1,185 ms; the equivalent literal-built record stayed near 1.3 ms. |
| [02](02-nominal-pattern-segfault/) | Reproduced with both omitted and nonexistent nominal fields. The minimal app crashed in 20/20 uncached checks on both tested nightlies; its corrected pattern checks cleanly. |
| [03](03-roc-test-speed-link/) | macOS linker symptom not testable on Linux. Speed-backend tests pass on both nightlies when `TMPDIR` is executable; this host's default no-exec `/tmp` otherwise causes an unrelated `PermissionDenied`. |
| [04](04-opt-interpreter-link/) | macOS linker symptom not testable on Linux, but the backend is still broken here too: both nightlies report a successful interpreter build and the resulting hello-world immediately segfaults. |
| [05](05-nested-list-clone/) | Reproduced and reduced to one fixed-size inner list. With 1 M elements, 100/200/400 writes through `List.update` took 286/570/1,148 ms; the equivalent singleton-list rebuild took 1.5/1.8/2.1 ms. |
| [06](06-list-reserve-quadratic/) | Reproduced. At 4 M appends, repeated `reserve` took 3.00 s and plain append 10.4 ms (old nightly: 2.94 s and 10.4 ms), with the same quadratic scaling. |
| [07](07-helper-not-inlined/) | Reproduced. The helper loops took 18–19 ms versus 4–6 ms inline, the same roughly fourfold gap as the old nightly. |
| [08](08-docs-expect-opt-speed/) | Reproduced, and the contradictory note is still present at compiler commit `e9be50a` and on `main`: speed/size omit the condition while a small dev run remains quadratic. |

Checksums matched across every mode in the timing reproducers. Issues 03 and 04 need a fresh
macOS run before filing their original platform-specific symptoms; the other six reproduce on
the latest nightly.

## Summary

| # | Problem | Kind | Impact on us |
|---|---|---|---|
| [01](01-record-field-clone/) | A list field is copied on every `set` when a two-field record is built by a call and later consumed by a helper; the equivalent literal stays in place | Silent quadratic work | Reshaped the entire solver API |
| [02](02-nominal-pattern-segfault/) | Compiler SIGSEGV when an app uses a function with an invalid nominal record pattern | Compiler crash | A type error terminates the compiler with no source location |
| [03](03-roc-test-speed-link/) | `roc test --opt=speed` cannot link on macOS: `library not found for -lSystem` | Toolchain | No speed-backend unit tests |
| [04](04-opt-interpreter-link/) | `--opt=interpreter` cannot produce a runnable hello-world (link failure on macOS, crashing output on Linux) | Toolchain | None; backend unusable |
| [05](05-nested-list-clone/) | `List.update` increfs a nested element before its callback, so mutation copies the full inner list before replacing it | Quadratic builtin | Ruled out nested lists entirely |
| [06](06-list-reserve-quadratic/) | `List.reserve(k)` sets capacity to exactly `len + k`, defeating geometric growth | Quadratic builtin | Trap avoided after measuring |
| [07](07-helper-not-inlined/) | A four-line same-module helper is not inlined into a hot loop (~6.6 ns/call) | Missed optimisation | Hot loops written as one function |
| [08](08-docs-expect-opt-speed/) | Mini-tutorial says `--opt=speed` does not discard `expect`s yet; it does | Docs | Wrong early design assumption |

Suggested order for the remaining reports: **05**, then **06**, **03**, **08**, **07**, **04**.

## The two that shaped the project

**01 — record field projection.** A SAT solver's state is naturally one record of flat arrays:
clause arena, watch pool, offsets, lengths, capacities, trail, values, levels, reasons. On this
nightly we could not find a way to thread that record through mutating functions without some
list being copied somewhere, and which shapes copy is not predictable from the source. The
symptom is not an error or a leak — the answer is correct and memory at rest is unchanged, the
program just gets slower in proportion to the data. What we shipped instead: every mutating
function takes the individual lists it mutates as parameters and returns them in a tuple, so
`propagate` has 13 parameters and returns a 13-tuple and every call site writes twelve
reassignments. That is not a shape anyone would choose; it is the only one we measured as
reliably in place (11 of 11 variants, versus 28 of 51 record variants cloning).

**05 — nested lists.** Watch lists, the central data structure of a CDCL solver, are naturally
`List(List(entry))`. That representation is quadratic here, so they became one flat `List(U32)`
pool with hand-managed per-literal offsets, lengths and capacities, plus relocation and
compaction — several hundred lines whose only reason to exist is that the natural
representation is unusable.

Both cost real time and both are invisible without a benchmark. What made them expensive is not
that in-place mutation sometimes fails; it is that there is no way to ask the compiler whether
it succeeded. The project now keeps a timing canary (`make canary`) on a fixed 2 M-clause instance
with a hard ceiling, purely to detect a future nightly flipping one of these shapes.

## Not reproduced

These are in the project's notes as things we hit, but they do not reproduce from the committed
state on this nightly. They are recorded here so nobody re-derives them, and so nobody files
them without a reproducer.

- **DRAT byte-buffer corruption under `--opt=speed`.** A commit message and the simplify backlog
  record that growing a long-lived `List(U8)` byte by byte (`lits.fold(proof, append_lit)`
  directly onto the persistent buffer) corrupted the buffer and segfaulted at process teardown
  on a minimised 9-clause input, with `--opt=dev` unaffected; the fix was to build each line
  separately and `concat` once. Re-tested: the pre-fix source at commit `356b0e3` builds clean
  at `--opt=speed --no-cache` and produces byte-identical proofs to the current binary on the
  minimised input and on 490 UNSAT corpus instances (uuf50, uuf100, hole, dubois, aim) with no
  bad exit codes. An independent stress program that grows a buffer through the same helper
  shapes, checked speed against dev, also matched. So the exact failing source state is not in
  git history. **If this recurs, capture the tree before fixing it** — a miscompile that
  corrupts memory is the most valuable report on this list.
- **`--opt=speed`-only integer-overflow crash** in a destructure-and-loop function, absent at
  `--opt=size` and `--opt=dev` (milestone-1 decision log). Not minimised at the time, source not
  preserved, no reproducer now.
- **`List.drop_last` / `List.take_first` poisoning uniqueness.** The claim is that a list that
  has flowed through them is treated as maybe-shared and copied on its next write. Tested five
  shapes — identity `drop_last(0)` and `take_first(m)` in a `var` loop, a push/pop stack, the
  pop behind a helper, and a helper returning `(list, len)` as a tuple — all linear, none
  copying. The solver's fixed-capacity trail buffers are keeping a workaround for something we
  cannot now demonstrate.
- **Records with more than 16 fields breaking the field-take optimisation.** Tested the
  destructure-mutate-rebuild loop at 2, 4, 8, 12, 16, 17, 18, 20 and 24 list fields: 9.4–10.4 ms
  across the whole range, no cliff.
- **Nominal-type method dispatch being 3× slower than a plain call.** Actively contradicted:
  in a clean comparison, nominal method 22.5 ms vs plain cross-module function 19.1 ms vs
  plain recursion 24.7 ms — all within call-overhead noise. The original 63 ms measurement
  compared a nominal method against a shape where the helper had been inlined, so it was
  measuring issue 07, not dispatch. Do not file this.

## Known gaps, working as documented

Not bugs; listed because they came up and someone will wonder.

- `continue` is not implemented (`NAME NOT IN SCOPE`). `docs/langref/statements.md` says so:
  "(This has not been implemented yet.)"
- The `list[i]` subscript operator is a documented TODO; `List.subscript` is an alias for
  `List.get`.
- The unchecked list primitives (`list_get_unsafe` and friends) are not reachable from
  application code. That is fine — the `range_prove` pass added in PR #10638 makes checked
  `.get(i)?` in a `while` loop cost exactly what `for` iteration and `fold` cost (re-measured
  2026-08-16 over 204.8 M reads: 79.0 / 78.2 / 78.7 ms respectively).
- There is no monotonic clock in the standard library or in basic-cli 0.22.0; `Utc.now!` is a
  wall clock at microsecond resolution. That is a basic-cli feature request, not a compiler
  issue, and it belongs in roc-lang/basic-cli.

## Reproducing any of this

```sh
roc version     # must print nightly-2026-08-18-e9be50a
cd upstream/<dir>
cat README.md   # exact commands and the numbers we measured
```

The repository pins the compiler in `roc-version` and runs it through `scripts/roc`, which
never falls back to a `roc` on `PATH`.
