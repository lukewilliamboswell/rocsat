# O(n) loop with an O(n) expect inside: quadratic if the expect runs, linear if dropped.
all_small = |xs, bound| xs.all(|x| x < bound)

main! = |args| {
    n = U64.from_str(args.get(0) ?? "1000") ?? 1000
    var $xs = List.repeat(0.U64, n)
    var $i = 0.U64
    while $i < n {
        $xs = $xs.set($i, $i) ?? $xs
        expect all_small($xs, n)          # true, O(n)
        expect $xs.len() == n + 1         # FALSE: does it abort / print?
        $i = $i + 1
    }
    echo!("sum=${$xs.fold(0.U64, |s, x| s + x).to_str()}\n")
    Ok({})
}
