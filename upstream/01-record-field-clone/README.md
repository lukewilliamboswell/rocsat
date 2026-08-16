# In-place list mutation through a record field depends on how the record was built

**Compiler:** `nightly-2026-08-13-2fdd90e`, `roc build --opt=speed`, arm64 macOS (Darwin 24.6.0).

## Problem

Mutating a `List` held in a record field — `{ ..st, blocks: st.blocks.set(i, v) ... }` — is
sometimes done in place and sometimes clones the whole list, once per operation. Which one you
get depends on details that carry no semantic weight:

- whether the record was produced by a **record literal** or by a **function call**, and
- whether the failure of `set` is handled with **`?`** or with **`??`**.

The four loops in `record_field_clone.roc` do identical work — `n` writes into a 32 MB
`List(U64)` and a small counter list, both fields of the same two-field record — and print
identical checksums. One of them is ~900× slower at n = 8 000, and its cost grows with `n`.

## Reproduce

```sh
roc build --opt=speed record_field_clone.roc
for m in literal_qq call_qq call_q lists; do
    for n in 2000 4000 8000; do
        /usr/bin/time -p ./record_field_clone $m 1000 4000 $n
    done
done
```

| mode | record built by | `set` error | n = 2 000 | n = 4 000 | n = 8 000 |
|---|---|---|---|---|---|
| `literal_qq` | record literal | `??` | 7.7 ms | 7.7 ms | 7.7 ms |
| `call_qq` | `new_state(m, cap)` | `??` | **1 934 ms** | **3 860 ms** | **7 701 ms** |
| `call_q` | `new_state(m, cap)` | `?` | 9.4 ms | 9.8 ms | 8.9 ms |
| `lists` | two separate values | `??` | 11.5 ms | 10.5 ms | 10.6 ms |

`call_qq` costs 0.96 ms per iteration and is linear in `n`: that is one full copy of the 32 MB
list per `set`. Peak RSS is exactly 2× — a transient second reference, not a leak.

## Cause, from the generated IR

`roc build --opt=speed --keep-temp` leaves the pre-LLVM-opt bitcode; `llvm-dis` on it shows the
difference at the `list_set` call sites of the very same source file.

Cloning path (`call_qq`):

```llvm
call void @roc_llvm_rc_incref_34_single_thread(ptr %10, i64 1, ptr null)
...
call void @roc_builtins_list_set(ptr %292, ptr %1104, i64 %1106, i64 %1108, i32 8,
                                 i64 %1109, ptr %289, i64 8, i1 false,
                                 ptr null, ptr null, i8 0, ptr null)
```

In-place path (same file, another mode):

```llvm
call void @roc_builtins_list_set(ptr %221, ptr %908, i64 %910, i64 %912, i32 8,
                                 i64 %913, ptr %218, i64 8, i1 false,
                                 ptr null, ptr null, i8 1, ptr null)
```

The projected field is increfed before the call and the trailing update-mode argument is `0`
instead of `1`, so the builtin sees refcount 2 and clones. There are no refcount operations
around the in-place call at all — the field is moved out. So this is ownership inference for
record field projection, not runtime behaviour.

## Why it matters

The cost is invisible: same answer, same memory profile at rest, no diagnostic. A program can
flip from linear to quadratic because a state record started being returned from a constructor
instead of being written inline, or because an error branch was rewritten from `?` to `??`.

In our case (a SAT solver whose state is one record of 13 flat lists) we could not find a
record-threading shape that was reliably in place, and ended up passing every mutated list as a
separate parameter and returning it in a tuple — `propagate` takes 13 arguments and returns a
13-tuple. That is the `lists` mode above: robust in every shape we tried (11 of 11), but it
makes the module API unreadable and it is not the shape the language wants you to write.

## Broader survey

We classified 62 code shapes on this workload (all with the compiler and flags above). Summary:

- **Record field projection: 28 of 51 shapes clone.** The dividing lines include: literal vs
  call-built record; `?` vs `??`; whether the record was passed to any function earlier in the
  scope; whether the mutation is in a `while` loop or in straight-line code; whether a read
  helper was called on the record before the write.
- **Separate list values: 11 of 11 shapes stay in place**, including cross-module calls,
  recursion, tuple returns, `Try` returns, nested loops, and rebuilding + destructuring a record
  every iteration.

## Files

| file | what |
|---|---|
| `record_field_clone.roc` | the four modes above, one file, no dependencies |
| `run.sh` | builds and prints the table above (min of 3 runs) |
