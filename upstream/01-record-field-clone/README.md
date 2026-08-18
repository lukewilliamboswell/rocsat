# Equivalent record initializers produce a ~900× `List.set` performance difference

Hi, I found this performance issue while working on my project.
Roc compiler version nightly-2026-08-18-e9be50a, tested with `--opt=speed` on Linux ARM64.
Here is the LLM-generated report for reproduction of the problem.

## Reproducer

Save this as `main.roc`:

```roc
main! = |args| {
    len = U64.from_str(args.get(0)?)?
    n = U64.from_str(args.get(1)?)?

    # In-place control:
    # var $s = { x: List.repeat(0.U64, len), y: 0 }
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

Build and run it with a one-million-element list:

```sh
roc build --opt=speed --output=app main.roc

time ./app 1000000 100
time ./app 1000000 200
time ./app 1000000 400
```

Minimum wall times over three runs were:

| initializer | 100 writes | 200 writes | 400 writes |
|---|---:|---:|---:|
| `new(len)` | 296 ms | 597 ms | 1,185 ms |
| equivalent record literal | 1.3 ms | 1.3 ms | 1.3 ms |

To run the control, swap the two initializer lines in the source and rebuild. Both versions print the same results. With 200 writes, increasing the list length from 250,000 to 500,000 to 1,000,000 increases the call-built time from 146 ms to 292 ms to 597 ms. The cost therefore scales with both list length and write count.

## Generated-code difference

Both builds retain `list_set` inside the runtime loop, so the fast version is not precomputed. The call-built loop increfs the list and selects the non-unique update path on every iteration:

```llvm
call void @roc_llvm_rc_incref_35_single_thread(...)
call void @roc_builtins_list_set(..., i8 0, ...)
```

The incref wrapper calls `roc_builtins_list_incref_single_thread`. The literal-built hot path has no corresponding incref and selects the unique update path:

```llvm
call void @roc_builtins_list_set(..., i8 1, ...)
```

This matches the observed full-list copy per `set`. I expected constructing the same uniquely owned record through a function call not to change the mutation loop's asymptotic cost.
