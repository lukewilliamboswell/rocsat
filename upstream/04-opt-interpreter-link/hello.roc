# `roc build --opt=interpreter hello.roc` fails to link on macOS:
#
#     ld64.lld: error: undefined symbol: _main
#     >>> referenced by the entry point
#     LINKER FAILED / Error: LinkFailed
#
# --opt=dev, --opt=speed and --opt=size all build and run this file.

main! = |_args| {
    echo!("hello\n")
    Ok({})
}
