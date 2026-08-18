# A list in a call-built record is copied on every mutation

**Compiler:** `nightly-2026-08-18-e9be50a`, Linux ARM64,
`roc build --opt=speed`.

## Minimal reproducer

`main.roc` creates a two-field record through `new`, repeatedly changes one element of its list,
and reads the result through a helper:

```roc
main! = |args| {
    len = U64.from_str(args.get(0)?)?
    n = U64.from_str(args.get(1)?)?

    # no copying
    # var $s = { x: List.repeat(0.U64, len), y: 0 }
    # copying
    var $s = new(len)
    var $i = 0
    while $i < n {
        $s = { ..$s, x: $s.x.set(0, $i) ?? $s.x }
        $i = $i + 1
    }

    echo!(read($s).to_str())
    Ok({})
}

new = |n| { x: List.repeat(0.U64, n), y: 0 }
read = |s| s.x.get(s.y) ?? 0
```

Build it and vary the U64 list's length and the number of writes:

```sh
roc build --opt=speed main.roc

./main 1000000 100
./main 1000000 200
./main 1000000 400
```

On `nightly-2026-08-18-e9be50a`, minimum wall times over three runs were:

| list length | writes | time |
|---:|---:|---:|
| 1,000,000 | 100 | 296 ms |
| 1,000,000 | 200 | 597 ms |
| 1,000,000 | 400 | 1,185 ms |
| 250,000 | 200 | 146 ms |
| 500,000 | 200 | 292 ms |

Time scales with both list length and write count: each `set` copies the whole list.

## One-line control

Change only the initializer:

```roc
# copies on every set
var $s = new(len)

# stays in place
var $s = { x: List.repeat(0.U64, len), y: 0 }
```

After rebuilding, the literal version takes about 1.3 ms at all three write counts and prints the
same results (`99`, `199`, and `399`). Constructing the same uniquely owned record through a
function call changes this loop from effectively linear to quadratic work.

The minimum shape needs two record fields and the `read($s)` helper after the loop. A one-field
record, or reading the final list directly instead of passing the record to `read`, stays in
place. Those details should not change whether the uniquely owned list can be mutated in place.

## Files

| file | what |
|---|---|
| `main.roc` | minimal reproducer |
| `run.sh` | builds it and measures both scaling dimensions |
