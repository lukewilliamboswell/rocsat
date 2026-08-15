main! = |args| {
    n = U64.from_str(args.get(0) ?? "3") ?? 3
    xs = List.repeat(7.U64, n)
    v = list_get_unsafe(xs, 1)
    echo!("v=${v.to_str()}\n")
    Ok({})
}
