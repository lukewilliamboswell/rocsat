main! = |args| {
    len = U64.from_str(args.get(0)?)?
    n = U64.from_str(args.get(1)?)?

    # no copying
    var $s = { x: List.repeat(0.U64, len), y: 0 }
    # copying
    # var $s = new(len)
    var $i = 0
    while $i < n {
        $s = { ..$s, x: $s.x.set(0, $i) ?? $s.x }
        $i = $i + 1
    }

    echo!(read($s).to_str())
    Ok({})
}

new = |n| { x: List.repeat(0.U64, n), y: 0 }
read = |s| s.x.get(s.y) ?? 0
