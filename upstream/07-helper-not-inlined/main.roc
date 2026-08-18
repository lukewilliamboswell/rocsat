main! = |args| {
    n = U64.from_str(args.get(0)?)?

    var $xs = [0.U64, 0]
    var $i = 0
    while $i < n {
        $xs = step($xs, $i)
        $i = $i + 1
    }

    Ok(echo!(($xs.get(0)? + $xs.get(1)?).to_str()))
}

step = |xs, i| {
    a = xs.set(0, i) ?? xs
    a.set(1, i) ?? a
}
