# `List.update` copies a nested list on every mutation

**Compiler:** `nightly-2026-08-18-e9be50a`, Linux ARM64, `roc build --opt=speed`.

## Minimal reproducer

The outer list has one fixed-size inner list. Nothing grows; the loop only changes element 0:

```roc
main! = |args| {
    len = U64.from_str(args.get(0)?)?
    n = U64.from_str(args.get(1)?)?

    var $outer = [List.repeat(0.U64, len)]
    var $i = 0
    while $i < n {
        $outer = $outer.update(0, |inner| inner.set(0, $i) ?? inner)?
        $i = $i + 1
    }

    inner = $outer.get(0)?
    echo!((inner.get(0)?).to_str())
    Ok({})
}
```

```sh
roc build --opt=speed --output=app main.roc

time ./app 1000000 100
time ./app 1000000 200
time ./app 1000000 400
```

Minimum wall times over three runs:

| inner length | writes | `List.update` |
|---:|---:|---:|
| 1,000,000 | 100 | 286 ms |
| 1,000,000 | 200 | 570 ms |
| 1,000,000 | 400 | 1,148 ms |
| 250,000 | 200 | 142 ms |
| 500,000 | 200 | 302 ms |

The cost scales with inner-list length × writes, even though every write targets the same element.

## Equivalent control

For this one-element outer list, replace the update with:

```roc
inner = $outer.get(0)?
$outer = [inner.set(0, $i) ?? inner]
```

The control produces the same results but takes 1.5, 1.8, and 2.1 ms for 100, 200, and 400
writes. It keeps the inner list unique and mutates it in place.

## Generated-code difference

The `List.update` path extracts the inner list while the outer list still owns it, increfs it,
and then invokes the callback:

```llvm
call void @roc_llvm_rc_incref_35_single_thread(...)
...
call void @roc_builtins_list_set(..., i8 0, ...)
call void @roc_builtins_list_replace(...)
```

The incref wrapper calls `roc_builtins_list_incref_single_thread`, so `list_set` receives a
shared inner list and copies it. Replacing the old inner list immediately afterward makes that
copy unobservable.

This appears distinct from [#10848](https://github.com/roc-lang/roc/issues/10848): this example
has no record, constructor helper, or record-field projection. Here the extra reference is
introduced while `List.update` passes a nested element to its callback. Both issues ultimately
lose uniqueness, but through different source and generated-code paths.
