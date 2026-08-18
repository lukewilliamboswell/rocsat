# A three-line helper makes a loop about seven times slower

Hi, I found this performance issue while working on my project.

**Compiler:** `nightly-2026-08-18-e9be50a`, Linux ARM64, `roc build --opt=speed`.

## Example

This program repeatedly changes both items in a two-item list. The helper is in the same file and is called from only one place.

```roc
main! = |args| {
    n = U64.from_str(args.get(0)?)?

    var $xs = [0.U64, 0]
    var $i = 0
    while $i < n {
        $xs = step($xs, $i)
        $i = $i + 1
    }

    Ok(echo!(($xs.get(0)? + $xs.get(1)?).to_str()))
}

step = |xs, i| {
    a = xs.set(0, i) ?? xs
    a.set(1, i) ?? a
}
```

Build and run it:

```sh
roc build --opt=speed --output=app main.roc

time ./app 20000000
time ./app 40000000
time ./app 80000000
```

These are the fastest times from five runs:

| loop count | helper call | same code written in the loop |
|---:|---:|---:|
| 20,000,000 | 75.4 ms | 10.5 ms |
| 40,000,000 | 150.6 ms | 20.4 ms |
| 80,000,000 | 300.8 ms | 40.3 ms |

To run the faster version, replace this line:

```roc
$xs = step($xs, $i)
```

with the helper body:

```roc
a = $xs.set(0, $i) ?? $xs
$xs = a.set(1, $i) ?? a
```

Both versions print the same result. The helper version costs about 3.2 ns more per loop iteration.

## What seems to happen

The final object file still contains a call from the loop to a separate 464-byte function for `step`. Writing the same code in the loop removes that call. A smaller helper containing only one `List.set` is inlined, but adding the second `List.set` is enough to keep this three-line source helper as a separate function.

I expected a speed build to inline this small helper, which is called from one place, or otherwise produce code close to the version with the body written directly in the loop.
