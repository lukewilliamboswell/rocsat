main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    cap = U64.from_str(args.get(2)?)?
    n = U64.from_str(args.get(3)?)?
    total =
        if mode == "a" {
            # a: bad() called with a call-expression argument, via a run_ wrapper
            run_a(m, cap, n)
        } else if mode == "b" {
            # b: bad() called with a local binding argument, via a run_ wrapper
            run_b(m, cap, n)
        } else if mode == "c" {
            # c: bad() called directly from main! with a local binding
            st0 = new_state(m, cap)
            checksum(bad(st0, n, m, cap))
        } else if mode == "d" {
            # d: bad() called directly from main! with a record literal
            st0 = { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
            checksum(bad(st0, n, m, cap))
        } else {
            # e: run_ wrapper, record literal inline
            run_e(m, cap, n)
        }
    echo!("mode=${mode} checksum=${total.to_str()}\n")
    Ok({})
}

new_state = |m, cap| { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
checksum = |st| st.counts.fold(0.U64, |s, x| s + x) + st.blocks.fold(0.U64, |s, x| s + x)

run_a = |m, cap, n| checksum(bad(new_state(m, cap), n, m, cap))
run_b = |m, cap, n| {
    st0 = new_state(m, cap)
    checksum(bad(st0, n, m, cap))
}
run_e = |m, cap, n| {
    st0 = { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
    checksum(bad(st0, n, m, cap))
}

bad = |st, n, m, cap| {
    var $st = st
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    $st
}
