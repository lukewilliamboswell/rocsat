# Four loops that do exactly the same work: n in-place writes into `blocks` (a 32 MB
# List(U64)) and `counts`, both held in a two-field record.
#
# They differ only in (a) whether the record was built by a literal or by a function call,
# and (b) whether the `set` error is handled with `?` or `??`. Neither is semantically
# relevant, but two of the four clone the whole 32 MB list on every iteration.
#
#   roc build --opt=speed record_field_clone.roc
#   ./record_field_clone literal_qq 1000 4000 8000   # ~10 ms, flat in n
#   ./record_field_clone call_qq    1000 4000 8000   # ~7700 ms, linear in n
#   ./record_field_clone call_q     1000 4000 8000   # ~10 ms
#   ./record_field_clone lists      1000 4000 8000   # ~10 ms

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    cap = U64.from_str(args.get(2)?)?
    n = U64.from_str(args.get(3)?)?

    total =
        if mode == "literal_qq" {
            # record built by a LITERAL, `??` on the set: in place
            var $st = { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
            var $i = 0.U64
            while $i < n {
                lit = $i % m
                c = $st.counts.get(lit) ?? 0
                $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
                $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
                $i = $i + 1
            }
            checksum($st)
        } else if mode == "call_qq" {
            # identical loop, record built by a CALL: clones `blocks` every iteration
            var $st = new_state(m, cap)
            var $i = 0.U64
            while $i < n {
                lit = $i % m
                c = $st.counts.get(lit) ?? 0
                $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
                $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
                $i = $i + 1
            }
            checksum($st)
        } else if mode == "call_q" {
            # same as call_qq but with `?` instead of `??`: in place again
            run_call_q(m, cap, n)?
        } else {
            # the two lists as separate values: in place, and stable across every shape we tried
            var $blocks = List.repeat(0.U64, m * cap)
            var $counts = List.repeat(0.U64, m)
            var $i = 0.U64
            while $i < n {
                lit = $i % m
                c = $counts.get(lit) ?? 0
                $blocks = $blocks.set((lit * cap) + c, $i) ?? $blocks
                $counts = $counts.set(lit, c + 1) ?? $counts
                $i = $i + 1
            }
            checksum({ blocks: $blocks, counts: $counts })
        }

    echo!("mode=${mode} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}

new_state = |m, cap| { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }

checksum = |st| st.counts.fold(0.U64, |s, x| s + x) + st.blocks.fold(0.U64, |s, x| s + x)

run_call_q = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit)?
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}
