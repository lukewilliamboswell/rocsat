# Appending to an inner list of a `List(List(_))` clones it every time

**Compiler:** `nightly-2026-08-13-2fdd90e`, `roc build --opt=speed`, arm64 macOS.

## Problem

`List.update(outer, i, |inner| inner.append(x))` — and the equivalent `get` then `set` — copies
the inner list on every call, even when the outer list is uniquely owned and the inner list is
dead immediately afterwards. Filling `m` inner lists with `n` elements is `O(n² / m)`.

## Reproduce

```sh
roc build --opt=speed nested_list.roc
for n in 400000 800000 1600000 3200000; do ./nested_list update 1000 $n; done
```

Wall clock, min of 3, `m = 1000` inner lists:

| n | `update` | `getset` | `flat` (one flat list, reference) |
|---|---|---|---|
| 400 000 | 35.7 ms | 33.9 ms | 3.1 ms |
| 800 000 | 97.9 ms | 95.4 ms | 3.9 ms |
| 1 600 000 | 361.2 ms | 364.4 ms | 5.0 ms |
| 3 200 000 | 1 594.5 ms | 1 506.4 ms | 8.8 ms |

Time roughly quadruples per doubling of `n`. The other axis gives the same signature — holding
`n = 3 200 000` and varying the number of inner lists:

| m | 250 | 1 000 | 4 000 | 16 000 | 64 000 |
|---|---|---|---|---|---|
| `update` | 7 186 ms | 1 487 ms | 532 ms | 367 ms | 249 ms |

Cost falls with `m`, i.e. it scales with the average inner length — the length of the copy.

## Cause

From `Builtin.roc`:

```roc
update = |list, index, func|
    Ok(list_replace_unsafe(list, index, func(list_get_unsafe(list, index))).list)
```

`list_get_unsafe` hands `func` a second reference to the inner list while the outer list still
holds the first, so the `append` inside `func` sees refcount 2 and clones. The original is then
overwritten by `list_replace_unsafe`, so the copy is never observed — it is pure waste.

A version that takes the element out of the outer list before calling `func` (leaving a hole /
poison value that `list_replace_unsafe` immediately fills) would let `func` mutate in place.

## Why it matters

`List(List(_))` is the obvious representation for adjacency lists, watch lists, buckets, and
per-key accumulators, and this makes all of them quadratic with no diagnostic. We measured this
first, before writing any solver code, and it forced every per-literal structure into one flat
`List(U32)` pool with hand-managed offsets, lengths and capacities — several hundred lines that
exist only to avoid nesting lists.

## Files

| file | what |
|---|---|
| `nested_list.roc` | `update`, `getset` and a flat-list reference, in one file |
| `run.sh` | builds and prints the n-scaling table (min of 3 runs) |
