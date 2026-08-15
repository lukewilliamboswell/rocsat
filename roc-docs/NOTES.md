# Roc — current state notes (for the rocsat project)

Retrieved **2026-08-14**. Roc is moving fast; re-run `./refresh.sh` and re-read this
before trusting anything below. Everything here is from the **new (Zig) compiler**
rewrite, not the old alpha4 compiler.

## Provenance of the files in this folder

| File | Source |
|---|---|
| `mini-tutorial-new-compiler.md` | `roc-lang/roc:docs/mini-tutorial-new-compiler.md` |
| `langref/*.md` | `roc-lang/roc:docs/langref/*.md` (marked heavily WIP) |
| `all_syntax_test.roc` | `roc-lang/roc:test/echo/all_syntax_test.roc` |
| `Builtin.roc` | `roc-lang/roc:src/build/roc/Builtin.roc` — the whole stdlib, 23k lines |
| `faq.md` | scraped from roc-lang.org/faq — **describes the OLD compiler in places** |

Warning that appears in Roc's own docs: everything on roc-lang.org refers to the old
compiler and old design. Trust `docs/` in the repo and `Builtin.roc` over the website.
The langref itself carries a "heavily WIP" banner and has `TODO` sections.

## What changed vs. the old Roc (the parts that matter here)

Roc is no longer a "no mutation, no loops" language at the surface level.

- **`var $x` mutable locals.** Reassignable within the declaring function only; cannot be
  reassigned from inside a nested closure (so `for_each!` can't touch them, but `for` can).
- **`for` loops** over iterators and ranges (`1..<5`, `1..=5`, `.step_by(n)`, `.iter_rev()`).
- **`while` loops** with a boolean condition.
- **`break`** exits the innermost loop. **`continue` is documented but NOT implemented yet.**
- **`return`**, **`crash`**, **`expect`**, **`dbg`** statements.
- `match` (was `when`), `Try`/`Ok`/`Err` (was `Result`), `Bool.True`/`Bool.False`,
  `List(U8)` parens (was `List U8`), `if/else` (no `then`).
- **Static dispatch**: `x.foo()` resolves to `Type.foo(x)` at compile time from the inferred
  type. Operators desugar to methods (`+` → `plus`, `<` → `is_lt`, `..<` → `range_exclusive_to`,
  unary `-` → `negate`, `!` → `not`).
- Nominal types with `:=`. `where [a.to_str : a -> Str]` method constraints.
- Effectful functions: `!` suffix by convention, `=>` arrow in types; purity is inferred.
  Only effectful functions can call effectful functions.
- Default number type for unconstrained literals is `Dec` (128-bit fixed point), not a float.

## Memory model / performance model

- Perceus "functional-but-in-place" reference counting, **atomic** refcounts.
- Heap-allocated and refcounted: **strings, lists, boxes, recursive tag unions**.
  Stack-allocated, not refcounted: **numbers, records, tuples, non-recursive tag unions**.
- Opportunistic mutation: builtin ops mutate in place at refcount 1, otherwise shallow-clone
  first. Documented in `langref/expressions.md`.
- No pointers, no reference equality, no way to observe addresses, no reference cycles.
- Tail-call optimization: a self-recursive function whose recursive calls are *all* tail calls
  is compiled to a `while` loop. Non-tail recursion can stack overflow.
- All pure top-level values are evaluated at compile time (constant folding is aggressive).
- `expect` is compiled out under `--opt=speed` (not yet, but "could be at any moment") — so
  invariant checks via `expect` are free in release builds.

## `List` API facts relevant to a SAT solver

From `Builtin.roc`. Public API is **bounds-checked and returns `Try`**:

```
get     : List(item), U64 -> Try(item, [OutOfBounds, ..])
subscript: List(item), U64 -> Try(item, [OutOfBounds, ..])   # the future list[i] operator
set     : List(a), U64, a -> Try(List(a), [OutOfBounds, ..])
replace : List(a), U64, a -> Try({ list : List(a), prev : a }, [OutOfBounds, ..])
update  : List(a), U64, (a -> a) -> Try(List(a), [OutOfBounds, ..])
swap    : List(a), U64, U64 -> Try(List(a), [OutOfBounds, ..])
with_capacity : U64 -> List(item)
reserve : List(item), U64 -> List(item)
release_excess_capacity : List(item) -> List(item)
append, prepend, insert, concat, append_sublist, copy_range_within, ...
fold, fold_with_index, fold_until, fold_with_index_until, fold_try
iter, iter_rev, from_iter
sort_with : List(item), (item, item -> [LT, EQ, GT]) -> List(item)
```

`subscript` is currently just an alias for `get` — the `list[i]` operator is documented
as a TODO in `langref/operators.md`.

**Unchecked primitives exist but are compiler-internal**, declared in `Builtin.roc` and not
(as far as I can tell) exposed to application code:

```
list_get_unsafe, list_set_unsafe, list_replace_unsafe, list_swap_unsafe,
list_append_unsafe, list_reserve, list_map_can_reuse, list_map_cast_unsafe,
list_map_extract_unsafe, list_map_write_unsafe
```

This is **the** open question for rocsat performance: whether the bounds check + `Try`
allocation-free unwrap in `get`/`set` optimizes away in a hot loop, and whether there is any
sanctioned escape hatch. `List.get` is written as `if index < len { Ok(unsafe) } else { Err }`,
so the branch is there in source; whether the backend elides it after a proven-in-range
comparison is unknown and must be measured, not assumed.

Numerics: full set of fixed-width ints `I8..I128`/`U8..U128`, plus wrapping and saturating
arithmetic (`plus_wrap`, `times_wrap`, `minus_wrap`, `plus_saturated`) and bit operations
(`shl_wrap`, `shr_wrap`, `bitwise_and`, `bitwise_or`, `bitwise_xor`). `Box(item)` exists.

## Platform / host

- Every app has exactly one platform; the stdlib has **no I/O at all**.
- The host (Zig/Rust/etc.) implements `main()`, provides `malloc`/`free`, and calls into the
  compiled Roc code. Arena allocation in the host is a real, used technique (`nea`).
- New-compiler platform templates:
  - https://github.com/lukewilliamboswell/roc-platform-template-zig
  - https://github.com/lukewilliamboswell/roc-platform-template-rust
  - basic-cli for the new compiler is WIP: roc-lang/basic-cli PR #423
- Headerless apps exist: a bare `main! = |_args| { ... }` with `echo!` works with no header.
- Get the compiler from https://github.com/roc-lang/nightlies/releases (`roc version` prints
  e.g. `nightly-2026-July-31-123c5d7`).

## Known not-yet-implemented (as of these docs)

- `continue` statement
- Exhaustiveness checking (not ported to the new compiler as of 2025-12-01 per the tutorial)
- `list[i]` subscript operator
- Nonblocking compilation (`roc check`-then-run)
- `--opt=speed` does not yet drop `expect`s

## Best help channel

Roc Zulip: https://roc.zulipchat.com/ — `#beginners`, and `#contributing > language reference`.
For questions about compiler-internal unsafe list ops and codegen quality, Zulip is likely the
only source of truth.
