# Q3: the flat fallback that Q2's result forces.
#
# Watch lists as a flat arena: m blocks of `cap` slots in one List(U64), plus a
# separate List(U64) of per-block counts. Append = write at block*cap+count, bump
# count. All operations touch only flat lists of a scalar type.
#
# modes:
#   vars    - the two lists held in two separate `var`s
#   record  - both lists held in one record, solver-style: { ..$st, blocks: ..., counts: ... }
#   split   - record, but destructured into vars for the loop and rebuilt at the end

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    cap = U64.from_str(args.get(2)?)?
    n = U64.from_str(args.get(3)?)?

    total =
        if mode == "vars" {
            run_vars(m, cap, n)?
        } else if mode == "record" {
            run_record(m, cap, n)?
        } else {
            run_split(m, cap, n)?
        }

    echo!("mode=${mode} m=${m.to_str()} cap=${cap.to_str()} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}

run_vars = |m, cap, n| {
    var $blocks = List.repeat(0.U64, m * cap)
    var $counts = List.repeat(0.U64, m)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $counts.get(lit)?
        $blocks = $blocks.set((lit * cap) + c, $i)?
        $counts = $counts.set(lit, c + 1)?
        $i = $i + 1
    }
    Ok($counts.fold(0.U64, |s, x| s + x) + $blocks.fold(0.U64, |s, x| s + x))
}

run_record = |m, cap, n| {
    var $st = { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit)?
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok($st.counts.fold(0.U64, |s, x| s + x) + $st.blocks.fold(0.U64, |s, x| s + x))
}

run_split = |m, cap, n| {
    st = { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
    { blocks, counts } = st
    var $blocks = blocks
    var $counts = counts
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $counts.get(lit)?
        $blocks = $blocks.set((lit * cap) + c, $i)?
        $counts = $counts.set(lit, c + 1)?
        $i = $i + 1
    }
    out = { blocks: $blocks, counts: $counts }
    Ok(out.counts.fold(0.U64, |s, x| s + x) + out.blocks.fold(0.U64, |s, x| s + x))
}
