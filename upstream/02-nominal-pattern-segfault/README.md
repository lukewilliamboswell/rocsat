# Compiler SIGSEGV on invalid nominal record patterns

Hi, I found two closely related compiler crashes while working on my project.

## Version

```text
Roc compiler version nightly-2026-08-18-e9be50a
```

Tested on Linux ARM64.

## Reproducer 1: omitted field

Save this as `main.roc`:

```roc
A := { a : Str }.{
    f : A -> Str
    # Should be: |A.{ .. }| ""
    f = |A.{}| ""
}

main! = |_| Ok(echo!(A.f(A.{ a: "" })))
```

The pattern is missing both `a` and `..`.

## Reproducer 2: nonexistent field

This variant asks for a field that is not in the nominal record, even though the pattern is
open:

```roc
A := { a : Str }.{
    f : A -> Str
    f = |A.{ b, .. }| b
}

main! = |_| Ok(echo!(A.f(A.{ a: "" })))
```

## Reproduce

```sh
roc check --no-cache main.roc
echo $?
```

Both examples consistently exit 139 and print:

```text
Segmentation fault (SIGSEGV) in the Roc compiler.
...
Please report this issue at: https://github.com/roc-lang/roc/issues
```

I expected `roc check` to report an invalid nominal type and exit normally instead of crashing.
For the first example, changing the pattern to `A.{ .. }` makes it check successfully.
