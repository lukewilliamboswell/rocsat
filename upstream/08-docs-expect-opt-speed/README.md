# Docs: the mini-tutorial says `--opt=speed` does not discard `expect`s yet — it does

**Compiler:** `nightly-2026-08-13-2fdd90e`, arm64 macOS.

## Problem

`docs/mini-tutorial-new-compiler.md` line 310 carries this note:

> Note: `--opt=speed` does not discard `expect`s yet but it could be implemented at any moment.

It has been implemented — PR #9842, merged 2026-06-28 ("Optimized builds now omit inline expect
conditions before lowering them into runtime code"). The surrounding prose (lines 308 and
337–339) already describes the implemented behaviour, so only the note is stale, and it says
the opposite of the paragraphs around it.

## Reproduce

`expect_cost.roc` puts an `O(n)` `expect` inside an `O(n)` loop, so a build that evaluates the
condition is quadratic and one that strips it is linear.

```sh
roc build --opt=speed expect_cost.roc && ./expect_cost 200000   # 0.22 s
roc build --opt=size  expect_cost.roc && ./expect_cost 200000   # 0.16 s
roc build --opt=dev   expect_cost.roc && ./expect_cost 200000   # does not finish
```

## Why it is worth fixing

The note is the difference between "invariant checks are free in release, use them everywhere"
and "invariant checks cost production time, use them sparingly", which is a design decision
taken early and expensive to revisit. We took the pessimistic reading from the docs, then had
to measure the compiler to find out it was wrong.

## Suggested change

Delete line 310. If a note is wanted in its place, state what is true: inline `expect`s are
omitted from `--opt=speed`, `--opt=size` and the default `roc build`, and kept by `--opt=dev`
and `roc run`, where a failure prints `Expect failed` to stderr and execution continues.

## Files

| file | what |
|---|---|
| `expect_cost.roc` | the quadratic-if-kept loop used for the timings above |
