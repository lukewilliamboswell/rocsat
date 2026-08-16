# Demonstrates the behaviour the docs describe as not-yet-implemented.
#
#   roc build --opt=speed expect_cost.roc && ./expect_cost 200000   # 0.22 s
#   roc build --opt=size  expect_cost.roc && ./expect_cost 200000   # 0.16 s
#   roc build --opt=dev   expect_cost.roc && ./expect_cost 200000   # does not finish
#
# The loop body carries an O(n) `expect` inside an O(n) loop. Speed and size builds run
# in linear time, so the condition is not evaluated at all; the dev build is quadratic,
# so it is. That is the behaviour of PR #9842 and it is what the two doc lines below
# say has not happened yet.

main! = |args| {
    n = U64.from_str(args.get(0)?)?
    var $xs = List.repeat(0.U64, n)
    var $i = 0.U64
    while $i < n {
        $xs = $xs.set($i, $i) ?? $xs
        expect all_small($xs, n)
        $i = $i + 1
    }
    echo!("n=${n.to_str()} sum=${$xs.fold(0.U64, |s, x| s + x).to_str()}\n")
    Ok({})
}

all_small = |xs, n| xs.fold(Bool.True, |acc, x| acc and x <= n)
