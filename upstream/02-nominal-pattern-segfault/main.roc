# `roc check main.roc` and `roc build main.roc` segfault on ~9 runs out of 10.
# On the tenth they report the type error in Sol.roc correctly, so the crash is
# nondeterministic. It needs the *importing* module: `roc check Sol.roc` never crashes.
import Sol

main! = |_args| {
    st = Sol.new(4)
    echo!("${Sol.total(st).to_str()}\n")
    Ok({})
}
