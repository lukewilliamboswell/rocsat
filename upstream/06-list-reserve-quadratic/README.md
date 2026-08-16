# `List.reserve` sets capacity exactly, so calling it while appending is quadratic

**Compiler:** `nightly-2026-08-13-2fdd90e`, `roc build --opt=speed`, arm64 macOS.

## Problem

`List.reserve(list, k)` requests capacity `len + k` and that request is trusted verbatim — it
does not take the geometric growth path. So the natural "make room for the next chunk" loop
reallocates and copies the whole list on every call:

```roc
if $i % k == 0 {
    $xs = $xs.reserve(k)     # capacity becomes exactly len + k, again and again
}
$xs = $xs.append(...)
```

Meanwhile plain `List.append` — which is `reserve(list, 1)` plus `list_append_unsafe` — *does*
grow geometrically, because a request of exactly `old_capacity + 1` is the one case
`calculateCapacity` treats as growth. The result is that the call a user reaches for to make
appending cheaper is the only one that is not amortised.

## Reproduce

```sh
roc build --opt=speed reserve.roc
for n in 1000000 2000000 4000000; do ./reserve reserve $n 4096; done
```

Wall clock, min of 3, `k = 4096`:

| n | `reserve` every k appends | plain `append` | hand-tracked doubling `reserve` |
|---|---|---|---|
| 1 000 000 | 117 ms | 5.0 ms | 5.1 ms |
| 2 000 000 | 499 ms (4.3×) | 7.2 ms | 7.3 ms |
| 4 000 000 | 2 517 ms (5.0×) | 12.4 ms | 11.9 ms |

Time roughly quadruples per doubling of `n`. The `manual` mode does the same number of
`reserve` calls but doubles the requested capacity by hand, and is as fast as plain `append` —
so the quadratic factor is entirely the growth policy, not the call.

## Suggested fix

Have `reserve` take `max(requested, geometric_growth(old_capacity))`, or at minimum return
early when `capacity >= len + k` is already true. Either would make the loop above linear
without changing what `reserve` guarantees.

If the exact-capacity behaviour is deliberate (`reserve` as "set capacity to exactly this"),
then the docstring should say so. It currently reads

```roc
## Ensure this list has room for at least spare additional items.
reserve : List(item), U64 -> List(item)
```

which promises a lower bound on capacity, not an exact one, and nothing warns that using it in
a loop is asymptotically worse than not using it at all.

## Files

| file | what |
|---|---|
| `reserve.roc` | the three modes above, one file |
| `run.sh` | builds and prints the table above (min of 3 runs) |
