main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    cap = U64.from_str(args.get(2)?)?
    n = U64.from_str(args.get(3)?)?
    total =
        if mode == "p" {
            run_p(m, cap, n)
        } else if mode == "q" {
            run_q(m, cap, n)
        } else if mode == "r" {
            run_r(m, cap, n)
        } else if mode == "s" {
            run_s(m, cap, n)
        } else if mode == "t" {
            run_t(m, cap, n)
        } else if mode == "u" {
            run_u(m, cap, n)
        } else if mode == "v" {
            run_v(m, cap, n)?
        } else if mode == "w" {
            run_w(m, cap, n)?
        } else {
            run_x(m, cap, n)
        }
    echo!("mode=${mode} checksum=${total.to_str()}\n")
    Ok({})
}

new_state = |m, cap| { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
checksum = |st| st.counts.fold(0.U64, |s, x| s + x) + st.blocks.fold(0.U64, |s, x| s + x)

# p: named binding from a call, then var
run_p = |m, cap, n| {
    st0 = new_state(m, cap)
    var $st = st0
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    checksum($st)
}

# q: var directly from the call
run_q = |m, cap, n| {
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
}

# r: named binding from a literal, then var
run_r = |m, cap, n| {
    st0 = { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }
    var $st = st0
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    checksum($st)
}

# s: named binding from a call, then var, but the FIRST thing in the loop body is a
# whole-record call `$st = touch($st)` — does moving through a call "launder" it?
touch = |st| st

run_s = |m, cap, n| {
    st0 = new_state(m, cap)
    var $st = touch(st0)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    checksum($st)
}

# t: named binding from a call, then var, but mutate the LISTS as separate vars
run_t = |m, cap, n| {
    st0 = new_state(m, cap)
    var $blocks = st0.blocks
    var $counts = st0.counts
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

# u: named binding from a call, then destructure, then vars
run_u = |m, cap, n| {
    st0 = new_state(m, cap)
    { blocks, counts } = st0
    var $blocks = blocks
    var $counts = counts
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

# v: exactly q, but with `?` instead of `??`
run_v = |m, cap, n| {
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

# w: `?` on the sets, `??` on the get
run_w = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# x: `??` but with a fallback that is NOT the old list (crash-free constant)
run_x = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? [] }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? [] }
        $i = $i + 1
    }
    checksum($st)
}
