# `List.update` copies an inner list on every change

Hi, I found this performance issue while working on my project.

**Compiler:** `nightly-2026-08-18-e9be50a`, Linux ARM64, `roc build --opt=speed`.

## Example

This program creates an outer list containing one fixed-size inner list. The loop only changes the first item, so no list grows.

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

Build and run it:

```sh
roc build --opt=speed --output=app main.roc

time ./app 1000000 100
time ./app 1000000 200
time ./app 1000000 400
```

These are the fastest times from three runs:

| inner list length | changes | time |
|---:|---:|---:|
| 1,000,000 | 100 | 286 ms |
| 1,000,000 | 200 | 570 ms |
| 1,000,000 | 400 | 1,148 ms |
| 250,000 | 200 | 142 ms |
| 500,000 | 200 | 302 ms |

The time grows with both the inner list length and the number of changes, even though every change writes to the same item.

## Faster equivalent version

Because this outer list contains only one item, the loop can instead get the inner list and rebuild the outer list:

```roc
inner = $outer.get(0)?
$outer = [inner.set(0, $i) ?? inner]
```

This produces the same results, but takes 1.5, 1.8, and 2.1 ms for 100, 200, and 400 changes. Roc updates the inner list in place in this version.

## Why it appears to copy

In the generated code for `List.update`, Roc increases the inner list's reference count while the outer list still points to it. `List.set` therefore sees a shared list and copies it. `List.update` then immediately replaces the old inner list, so the copy cannot be observed by the program.

```llvm
call void @roc_llvm_rc_incref_35_single_thread(...)
...
call void @roc_builtins_list_set(..., i8 0, ...)
call void @roc_builtins_list_replace(...)
```

This looks separate from [#10848](https://github.com/roc-lang/roc/issues/10848). That issue needs a record built by a function call, while this example has no record and the extra reference appears inside `List.update`. Both problems cause an unnecessary list copy, but they reach it in different ways.
