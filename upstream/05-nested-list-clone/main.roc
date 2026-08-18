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
