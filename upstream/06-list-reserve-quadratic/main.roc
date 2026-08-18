main! = |args| {
    n = U64.from_str(args.get(0)?)?

    var $xs = []
    while $xs.len() < n {
        $xs = $xs.reserve(2)
        $xs = $xs.append(0)
        $xs = $xs.append(0)
    }

    Ok(echo!($xs.len().to_str()))
}
