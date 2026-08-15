# Q5 — does in-place mutation survive function and module boundaries?

Track B, question 1. **Compiler:** `nightly-2026-08-13-2fdd90e`, `roc build --opt=speed`,
arm64 macOS. **Workload:** the q3 flat block arena — `blocks : List(U64)` of m·cap = 4M
slots (32 MB) plus `counts : List(U64)` of m = 1000 — with n appends, one per iteration.
Every mode prints a checksum, verified against the closed form.

**Classification method:** at n = 100,000 a mode either finishes in ~10 ms or does not
finish in 4 s. There is nothing in between: the slow modes clone the 32 MB `blocks` list on
*every* iteration (0.97 ms/iter, linear in n, peak RSS exactly 2× — a transient second
reference, not a leak). 51 record-shaped modes in `main.roc`, 11 list-shaped modes in
`lists.roc`, plus two minimal repros.

---

## Verdict

1. **Cross-module and cross-function calls per se are fine.** A void module (`Arena.roc`),
   a nominal type with methods (`Sol.roc`), plain same-file functions, recursion, tuple
   returns and `Try` returns all mutate in place — *when the code shape is one of the
   robust ones below.* The module boundary changed nothing in any pair I tested.

2. **The record-of-lists shape is fragile.** Mutating a list *through a field projection of
   a record* — `st.blocks.set(i, v)`, `{ ..st, blocks: st.blocks.set(i, v)? }`,
   destructuring the record and then mutating — clones the whole list on every operation
   in **28 of 51** tested shapes. Whether it clones depends on things a programmer will not
   think of as semantically relevant: whether the record was built by a literal or returned
   by a call, whether the record was passed to any function earlier in the scope, whether an
   error is handled with `?` or `??`, whether the code sits in a `while` loop or in
   straight-line code. The same textual loop body flips between 6 ms and 3 s.

3. **Separate list values are robust.** With `blocks` and `counts` as individual values —
   function params, tuple returns, `Try((b, c), _)`, `var`-loops, recursion, cross-module,
   read helpers, `?` and `??`, nested loops, even rebuilding a record every iteration and
   destructuring it again — **11 of 11** shapes mutate in place.

4. **Cause, confirmed in the LLVM IR** (`roc build --keep-temp` leaves the unoptimized
   `.bc`): in a cloning shape the compiler copies the record, projects the `blocks` field
   out, calls `roc_llvm_rc_incref` on it, calls `roc_builtins_list_set` (which sees
   refcount 2 and clones), then `decref`s. In the working shape of the *same source* there
   are no refcount ops around `list_set` at all — the field is moved out. So it is the
   compiler's ownership inference for record field projection that is inconsistent, not
   the runtime. Repro files: `repro_seed.roc` (call-built vs literal-built record),
   `repro_fallback.roc` (`?` vs `??`).

5. **Function-call overhead is real but small.** Where a call happens per step, the loop
   costs ~22 ms vs ~6 ms inline for 3.2 M steps: ≈5 ns/call passing a 48-byte record in and
   out; ≈9 ns returning a tuple of two lists, ≈14 ns returning `Try((b, c), _)`. Roc's own
   pipeline inlined the step function into every caller in the IR I looked at, but LLVM's
   `-O` did not eliminate the copies. Nominal-type method dispatch (`$st.step(...)` on
   `Sol`) was 63 ms — 10× the inline loop, 3× the plain-function version; unexplained.
   Self-tail-recursion is TCO'd and costs the same as a `while` loop (7.5 ms).

## Design rule for rocsat

**Hot-path functions take and return the individual `List`s they mutate, never a record
whose fields they mutate through projection.** Concretely:

- The solver state may be a record *at rest* (returned from `solve`, held between calls),
  but every function that mutates lists destructures on entry — `{ blocks, counts, .. } = st`
  or a pattern in the parameter — mutates the local list bindings (`var $blocks = blocks`
  in a loop, or straight-line rebinding), and rebuilds the record on exit. `l_readrec`
  shows this costs nothing even when done every iteration (5.96 ms vs 5.69 ms).
- Helpers that need several lists take them as separate parameters and return a tuple.
  Cross-module is fine. `?` is fine.
- Never write `st.field.set(...)` or `{ ..st, field: st.field.set(...) }` in a hot path.
  It works in some contexts and silently costs a full copy per operation in others.
- Prefer inline `while` loops or self-tail-recursion for the innermost loop; a call per
  step costs 5–14 ns, which is more than the ~2 ns the step itself costs.
- **Add a canary benchmark to CI**: an `n`-scaling run of the actual propagate loop with a
  hard time ceiling. This nightly's behaviour is inconsistent enough that a future nightly
  could flip a working shape, and nothing but a timing test will detect it.

## Full table — record shapes (`main.roc`)

Times are the loop alone (full run minus an n=0 run), n = 3,200,000, min of 5. "CLONE"
means 0.97 ms per iteration at n=2000 and did not finish 100,000 iterations in 4 s.

### The five original sub-questions

| # | shape | mode | result |
|---|---|---|---|
| (a) | same-module fn, state in → state out, `??` inside | `fn` | 22.1 ms ✅ |
| (b) | cross-module fn (void module) | `mod` | 21.7 ms ✅ |
| (b') | cross-module nominal type method `$st.step(...)` | `nom` | 63.1 ms ✅ (slow) |
| (c) | fn returning `Try(st, _)`, `?` inside | `fn_try` / `mod_try` | **CLONE** |
| (c') | fn returning `Try(st, _)`, `??` inside, `Ok(...)` | `fn_ok` | 6.5 ms ✅ |
| (c'') | fn returning `Try(st, _)`, explicit `match` propagating `Err` | `fn_m` | 5.7 ms ✅ |
| (d) | fn returning `(st, U64)` | `fn_tuple` / `mod_tuple` | 30.7 ms ✅ |
| (e) | self-recursive fn threading st | `rec` / `mod_rec` / `nom_rec` | 7.5 / 7.5 / 21.6 ms ✅ |
| (e') | self-recursive fn threading st with `?` inside | `rec_q` | 7.4 ms ✅ |

### Everything else, grouped by what was varied

Baseline: `inline` — `var $st = new_state(m, cap)`, inline `{ ..$st, blocks: $st.blocks.set(..)? }` — **5.97 ms**.

| what varied | ✅ in place | ❌ CLONE |
|---|---|---|
| read helper on the record, then mutate **inline in the caller** | — | `fn_read`, `fn_read_pat` (destructuring param), `fn_read_both`, `fn_read_qq` (`??` in caller), `fn_read_alias`, `fn_read_full` (no `..` spread), `fn_read_setq`, `fn_read_destr` (destructure after the call), `mod_read` |
| read helper on the record, then mutate **via a function** | `fn_read_fn` 23.1, `fn_read_twice` 26.3, `nom_read` 23.1 | — |
| read helper on **just the list** | `fn_read_list` 6.3 | — |
| record returned from a fn, then mutated inline | — | `fn_ident`, `fn_read_thread` |
| `?` / `return` inside a non-recursive callee that mutates | — | `fn_q1` (`?` on the get only!), `fn_q2`, `fn_q3`, `fn_ret` (explicit `return Err`) |
| inside a callee: read helper then inline mutation | `nest_inline` 22.5 | — |
| inside a callee: read helper then write helper | — | `nest`, `nest_var` |
| inside a callee: intermediate named binding of the state | — | `seq` (`st2 = f(st); g(st2)`), `seq_var`, `try_var`, `after` |
| inside a callee: direct expression nesting / tail call | `pipe` (`g(f(st))`) 22.1, `deep` (3 levels) 22.4 | — |
| callee receives state, `var $st = st`, then `$st = f($st)` in a loop | `x_helpers` 19.0, `x_mod` 21.9 | — |
| callee receives state, `var $st = st`, inline mutation in a loop | — | `x_inline` (`?`), `y_qq` (`??`), `y_seeded`, `y_prime`, `x_two` (nested loops) |
| callee receives state, destructures into two list `var`s | `y_split` 7.2 | — |
| a bare list function with `?` inside, called with `$st.blocks` | `fn_list_q` 21.1 | — |

### Minimal repros (`repro_seed.roc`, `repro_fallback.roc`)

Same loop body `var $st = ...; while { c = $st.counts.get(lit) ...; $st = { ..$st, blocks: $st.blocks.set(..) ... } }`:

| seed of `$st` | error handling on `set` | result |
|---|---|---|
| record literal in the same function | `?? $st.blocks` | ✅ (`r`, and q3 `record` mode) |
| `new_state(m, cap)` — a call | `?? $st.blocks` | **CLONE** (`q`) |
| `new_state(m, cap)` | `?? []` | **CLONE** (`x`) |
| `new_state(m, cap)` | `?` | ✅ (`v`, `w`, and q5 `inline`) |
| `st0 = new_state(..)`, passed to a callee that does `var $st = st` | `??` | **CLONE** (`a`, `b`, `c`) |
| `st0 = { literal }`, passed to the same callee | `??` | ✅ (`d`, `e`) |
| `new_state(..)`, then `var $blocks = st0.blocks` etc. | `??` | ✅ (`t`, `u`) |

## Full table — separate lists (`lists.roc`)

All seeded from `new_state(m, cap)` destructured at the call site. n = 3,200,000, loop only.

| mode | shape | loop |
|---|---|---|
| `l_qq` | callee receives `(blocks, counts)`, `var`-loop, `??` | 5.7 ms ✅ |
| `l_q` | same, `?` | 4.1 ms ✅ |
| `l_step_qq` | `var`-loop calling `step_lists` → tuple, `??` inside | 29.1 ms ✅ |
| `l_step_q` | `var`-loop calling `step_lists_try` → `Try(tuple)`, `?` inside | 44.5 ms ✅ |
| `l_read` | read helper on the counts list, then inline set | 6.1 ms ✅ |
| `l_mod_qq` | cross-module `ArenaL.step` → tuple | 28.6 ms ✅ |
| `l_mod_q` | cross-module `ArenaL.step_try` → `Try(tuple)` | 43.9 ms ✅ |
| `l_two` | outer `var`-loop → inner `var`-loop, both over lists | 9.2 ms ✅ |
| `l_rec` | recursion threading `(b, c)`, `??` | 7.5 ms ✅ |
| `l_rec_q` | recursion threading `(b, c)`, `?` | 7.1 ms ✅ |
| `l_readrec` | record rebuilt and destructured **every iteration** | 6.0 ms ✅ |

## Also found

- **Compiler segfault:** an early version of `Sol.roc` had a type error (a nominal record
  pattern missing a field). `roc check` reported it correctly; `roc build --opt=speed`
  crashed with SIGSEGV. Fixed the source, did not minimize.
- `roc build --keep-temp` keeps `roc_app_llvm_<target>_speed_<hash>.bc` (pre-LLVM-opt
  bitcode) in `$TMPDIR/roc/<version>/<id>/`; `llvm-dis` (Homebrew LLVM) reads it. This is
  the answer to Track B Q6's "is there any way to inspect generated code" — grep for
  `roc_llvm_rc_incref` next to `roc_builtins_list_set`.

## Files

| file | what |
|---|---|
| `main.roc` | 51 record-shaped modes |
| `Arena.roc` | void module: `step`, `step_try`, `step_tuple`, `count_of`, `run` over a plain record |
| `Sol.roc` | nominal type with methods |
| `lists.roc` | 11 list-shaped modes |
| `ArenaL.roc` | void module over separate lists |
| `repro_seed.roc` | minimal: literal-built vs call-built record |
| `repro_fallback.roc` | minimal: `?` vs `??`, and list-var escape (`t`, `u`) |
| `bench.py` | timing harness (add a per-run timeout before using it on cloning modes) |

Rebuild: `roc build --opt=speed main.roc` (or `lists.roc`) with the release nightly.
