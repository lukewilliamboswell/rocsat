# Calling `List.reserve(2)` before two appends makes a loop quadratic

Hi, I found this performance issue while working on my project.

**Compiler:** `nightly-2026-08-18-e9be50a`, Linux ARM64, `roc build --opt=speed`.

## Example

This loop reserves room for two items and then appends two items:

```roc
main! = |args| {
    n = U64.from_str(args.get(0)?)?

    var $xs = []
    while $xs.len() < n {
        $xs = $xs.reserve(2)
        $xs = $xs.append(0)
        $xs = $xs.append(0)
    }

    Ok(echo!($xs.len().to_str()))
}
```

Build and run it with even values of `n`:

```sh
roc build --opt=speed --output=app main.roc

time ./app 10000
time ./app 20000
time ./app 40000
time ./app 80000
```

These are the fastest times from three runs:

| final list length | with `reserve(2)` | without the `reserve` line |
|---:|---:|---:|
| 10,000 | 152 ms | 0.35 ms |
| 20,000 | 588 ms | 0.48 ms |
| 40,000 | 2,322 ms | 0.79 ms |
| 80,000 | 9,307 ms | 1.30 ms |

To run the faster version, remove only this line and rebuild:

```roc
$xs = $xs.reserve(2)
```

Both versions print the same list length. Doubling the length makes the version with `reserve` about four times slower, while plain append stays close to linear.

## What seems to happen

`List.reserve(2)` appears to set the capacity to exactly the current length plus two. The next two appends fill that space, so the next call allocates again and copies the whole list. Plain append leaves extra space and does not copy on every growth.

The current documentation says:

```roc
## Ensure this list has room for at least spare additional items.
reserve : List(item), U64 -> List(item)
```

I expected reserving enough room for the next two appends not to make the loop much slower than appending without it. Either `reserve` could leave extra room when it grows, or the documentation could warn that repeatedly reserving fixed-size chunks causes this behavior.
