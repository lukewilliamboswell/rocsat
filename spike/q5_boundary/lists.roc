# Q5 part 2: are SEPARATE list values (not a record of lists) robust across the
# same boundaries that broke the record shapes in main.roc?
#
# modes (all seeded from a call, new_state, then destructured):
#   l_qq        var-loop inside a callee receiving (blocks, counts), `??`
#   l_q         same, `?`
#   l_step_qq   var-loop calling step_lists (returns tuple), `??` inside
#   l_step_q    var-loop calling step_lists_try (returns Try(tuple)), `?` inside
#   l_read      read helper on the counts list before inline set
#   l_mod_qq    cross-module ArenaL.step, `??`
#   l_mod_q     cross-module ArenaL.step_try, `?`
#   l_two       outer var-loop -> inner var-loop, both on lists
#   l_rec       recursive loop threading (blocks, counts)
#   l_rec_q     recursive loop with `?`
#   l_readrec   loop_lists but with record built/destructured every step

import ArenaL

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    cap = U64.from_str(args.get(2)?)?
    n = U64.from_str(args.get(3)?)?

    { blocks, counts } = new_state(m, cap)

    (b, c) =
        if mode == "l_qq" {
            loop_qq(blocks, counts, n, m, cap)
        } else if mode == "l_q" {
            loop_q(blocks, counts, n, m, cap)?
        } else if mode == "l_step_qq" {
            loop_step_qq(blocks, counts, n, m, cap)
        } else if mode == "l_step_q" {
            loop_step_q(blocks, counts, n, m, cap)?
        } else if mode == "l_read" {
            loop_read(blocks, counts, n, m, cap)
        } else if mode == "l_mod_qq" {
            loop_mod_qq(blocks, counts, n, m, cap)
        } else if mode == "l_mod_q" {
            loop_mod_q(blocks, counts, n, m, cap)?
        } else if mode == "l_two" {
            outer(blocks, counts, n, m, cap)
        } else if mode == "l_rec" {
            rec(blocks, counts, 0.U64, n, m, cap)
        } else if mode == "l_rec_q" {
            rec_q(blocks, counts, 0.U64, n, m, cap)?
        } else if mode == "l_readrec" {
            loop_readrec(blocks, counts, n, m, cap)
        } else {
            return Err(UnknownMode)
        }

    total = c.fold(0.U64, |s, x| s + x) + b.fold(0.U64, |s, x| s + x)
    echo!("mode=${mode} m=${m.to_str()} cap=${cap.to_str()} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}

new_state = |m, cap| { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }

loop_qq = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        k = $c.get(lit) ?? 0
        $b = $b.set((lit * cap) + k, $i) ?? $b
        $c = $c.set(lit, k + 1) ?? $c
        $i = $i + 1
    }
    ($b, $c)
}

loop_q = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        k = $c.get(lit)?
        $b = $b.set((lit * cap) + k, $i)?
        $c = $c.set(lit, k + 1)?
        $i = $i + 1
    }
    Ok(($b, $c))
}

step_lists = |b, c, lit, cap, i| {
    k = c.get(lit) ?? 0
    (b.set((lit * cap) + k, i) ?? b, c.set(lit, k + 1) ?? c)
}

loop_step_qq = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        (b2, c2) = step_lists($b, $c, $i % m, cap, $i)
        $b = b2
        $c = c2
        $i = $i + 1
    }
    ($b, $c)
}

step_lists_try = |b, c, lit, cap, i| {
    k = c.get(lit)?
    b2 = b.set((lit * cap) + k, i)?
    c2 = c.set(lit, k + 1)?
    Ok((b2, c2))
}

loop_step_q = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        (b2, c2) = step_lists_try($b, $c, $i % m, cap, $i)?
        $b = b2
        $c = c2
        $i = $i + 1
    }
    Ok(($b, $c))
}

count_of = |c, lit| c.get(lit) ?? 0

loop_read = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        k = count_of($c, lit)
        $b = $b.set((lit * cap) + k, $i) ?? $b
        $c = $c.set(lit, k + 1) ?? $c
        $i = $i + 1
    }
    ($b, $c)
}

loop_mod_qq = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        (b2, c2) = ArenaL.step($b, $c, $i % m, cap, $i)
        $b = b2
        $c = c2
        $i = $i + 1
    }
    ($b, $c)
}

loop_mod_q = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        (b2, c2) = ArenaL.step_try($b, $c, $i % m, cap, $i)?
        $b = b2
        $c = c2
        $i = $i + 1
    }
    Ok(($b, $c))
}

inner = |blocks, counts, k, base, m, cap| {
    var $b = blocks
    var $c = counts
    var $j = 0.U64
    while $j < k {
        i = base + $j
        lit = i % m
        cnt = $c.get(lit) ?? 0
        $b = $b.set((lit * cap) + cnt, i) ?? $b
        $c = $c.set(lit, cnt + 1) ?? $c
        $j = $j + 1
    }
    ($b, $c)
}

outer = |blocks, counts, n, m, cap| {
    var $b = blocks
    var $c = counts
    var $i = 0.U64
    while $i < n {
        (b2, c2) = inner($b, $c, 8, $i, m, cap)
        $b = b2
        $c = c2
        $i = $i + 8
    }
    ($b, $c)
}

rec = |b, c, i, n, m, cap| {
    if i >= n {
        (b, c)
    } else {
        lit = i % m
        k = c.get(lit) ?? 0
        rec(b.set((lit * cap) + k, i) ?? b, c.set(lit, k + 1) ?? c, i + 1, n, m, cap)
    }
}

rec_q = |b, c, i, n, m, cap| {
    if i >= n {
        Ok((b, c))
    } else {
        lit = i % m
        k = c.get(lit)?
        b2 = b.set((lit * cap) + k, i)?
        c2 = c.set(lit, k + 1)?
        rec_q(b2, c2, i + 1, n, m, cap)
    }
}

# rebuild a record each step and destructure it again — the "record at rest,
# lists in the loop" idiom, stressed
loop_readrec = |blocks, counts, n, m, cap| {
    var $st = { blocks, counts }
    var $i = 0.U64
    while $i < n {
        { blocks: b0, counts: c0 } = $st
        lit = $i % m
        k = c0.get(lit) ?? 0
        b1 = b0.set((lit * cap) + k, $i) ?? b0
        c1 = c0.set(lit, k + 1) ?? c0
        $st = { blocks: b1, counts: c1 }
        $i = $i + 1
    }
    ($st.blocks, $st.counts)
}
