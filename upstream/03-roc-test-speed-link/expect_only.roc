# `roc test --opt=speed expect_only.roc` fails to link on macOS:
#
#     ld64.lld: error: library not found for -lSystem
#     COMPILER ERROR ... LLVM speed test backend failed: LinkFailed
#     Ran 1 tests in 19.2 ms.: 0 passed, 0 failed, 1 compiler errors
#
# `roc test` (dev backend) passes, and `roc build --opt=speed` links fine — so the SDK
# library path the normal build passes to the linker is missing from the test backend's.

expect 1 + 1 == 2

main! = |_args| {
    echo!("hi\n")
    Ok({})
}
