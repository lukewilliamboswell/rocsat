# Q6 (Track B Q2): watch-list churn with removal.
#
# Simulates the access pattern of `propagate` on a two-watched-literal scheme:
# visit the watch list of a random literal p, keep most entries (blocker check),
# and MOVE ~25% of them to another random literal's list (a new watch was found).
# Entries are never created or destroyed after the initial build, so the total
# number of watches T is constant and the per-literal multiset is identical
# across all schemes at every step (move decisions hash the entry id and the
# step number, so they do not depend on traversal order).
#
# Schemes:
#   pool*      Track A's recommendation (A): one flat U32 pool of 2-word entries
#              [blocker, cref], per-literal wofs/wlen/wcap, in-loop compaction on
#              traversal, relocation with doubling on overflow, optional
#              compaction (rebuild into a fresh pool) when garbage exceeds a
#              threshold or every `period` steps.
#   linked     Track A's alternative (C): intrusive singly-linked lists threaded
#              through per-entry index arrays (next/eblk), push-front, unlink
#              during traversal.
#
# usage: churn <mode> <L literals> <T entries> <R steps> [period=0] [stride=8]
#   stride = words per clause in the simulated clause arena (see `arena` below)
#   pool         exact-fit initial capacities, never compact
#   pool_gc      exact-fit, compact when garbage > 3/4 of pool and pool > 2^18 words
#   pool_slack   caps = len + len/2 + 2 at build and at compaction, gc as above
#   pool_pow2    caps = next pow2 >= max(4, len) at build and at compaction, gc as above
#   pool_loop    like pool_gc but relocation copies with a manual set loop
#   pool_period  like pool_gc plus an unconditional rebuild every `period` steps
#   pool_period_slack / pool_period_pow2   same with the Half / Pow2 capacity policy
#   linked       intrusive linked lists
#
# Clause arena: both schemes also touch a simulated clause arena of T*stride
# U32 words. The pool scheme reads arena[cref*stride] only on a blocker miss
# (as real propagate does); the linked scheme keeps its `next` link and its
# blocker IN the arena (arena[e*stride+1], arena[e*stride]) so every entry visit
# touches the arena, which is the structural difference Track A describes.

main! = |args| {
    mode = args.get(0)?
    l = U64.from_str(args.get(1)?)?
    t = U64.from_str(args.get(2)?)?
    r = U64.from_str(args.get(3)?)?
    period = U64.from_str(args.get(4) ?? "0") ?? 0
    stride = U64.from_str(args.get(5) ?? "8") ?? 8

    out =
        if mode == "pool" {
            run_pool(l, t, r, stride, { slack: Exact, gc: Bool.False, manual_copy: Bool.False, period: 0 })?
        } else if mode == "pool_gc" {
            run_pool(l, t, r, stride, { slack: Exact, gc: Bool.True, manual_copy: Bool.False, period: 0 })?
        } else if mode == "pool_slack" {
            run_pool(l, t, r, stride, { slack: Half, gc: Bool.True, manual_copy: Bool.False, period: 0 })?
        } else if mode == "pool_pow2" {
            run_pool(l, t, r, stride, { slack: Pow2, gc: Bool.True, manual_copy: Bool.False, period: 0 })?
        } else if mode == "pool_loop" {
            run_pool(l, t, r, stride, { slack: Exact, gc: Bool.True, manual_copy: Bool.True, period: 0 })?
        } else if mode == "pool_period" {
            run_pool(l, t, r, stride, { slack: Exact, gc: Bool.True, manual_copy: Bool.False, period: period })?
        } else if mode == "pool_period_slack" {
            run_pool(l, t, r, stride, { slack: Half, gc: Bool.True, manual_copy: Bool.False, period: period })?
        } else if mode == "pool_period_pow2" {
            run_pool(l, t, r, stride, { slack: Pow2, gc: Bool.True, manual_copy: Bool.False, period: period })?
        } else if mode == "linked" {
            run_linked(l, t, r, stride)?
        } else {
            return Err(UnknownMode)
        }

    echo!("mode=${mode} L=${l.to_str()} T=${t.to_str()} R=${r.to_str()} checksum=${out.checksum.to_str()} touch=${out.touch.to_str()} moves=${out.moves.to_str()} relocs=${out.relocs.to_str()} compacts=${out.compacts.to_str()} words=${out.words.to_str()}\n")
    Ok({})
}

# ---------------------------------------------------------------- shared

# 64-bit LCG (Knuth MMIX constants); we use the top bits.
next_rng = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)
rng_below = |x, n| x.shr_wrap(33) % n

# order-independent per-entry decision hash
mix = |cref, step| {
    h0 = cref.plus_wrap(1).times_wrap(2654435761).bitwise_xor(step.to_u32_wrap().times_wrap(2246822519))
    h1 = h0.bitwise_xor(h0.shr_wrap(16)).times_wrap(73244475)
    h1.bitwise_xor(h1.shr_wrap(16))
}

# initial assignment of entries to literals: (lit, blocker) for entry e, from a fresh rng
gen_entries = |l, t| {
    var $rng = 88172645463325252.U64
    var $elit = List.with_capacity(t)
    var $eblk = List.with_capacity(t)
    var $e = 0.U64
    while $e < t {
        $rng = next_rng($rng)
        $elit = $elit.append(rng_below($rng, l).to_u32_wrap())
        $rng = next_rng($rng)
        $eblk = $eblk.append(rng_below($rng, l).to_u32_wrap())
        $e = $e + 1
    }
    # per-literal "value" (1 = blocker satisfied): half the literals
    var $val = List.with_capacity(l)
    var $i = 0.U64
    while $i < l {
        $rng = next_rng($rng)
        $val = $val.append(rng_below($rng, 2).to_u8_wrap())
        $i = $i + 1
    }
    (elit, eblk, val) = ($elit, $eblk, $val)
    { elit, eblk, val }
}

# simulated clause arena: word e*stride holds a payload, word e*stride+1 is free for a link
gen_arena = |t, stride| {
    var $arena = List.repeat(0.U32, t * stride)
    var $e = 0.U64
    while $e < t {
        $arena = $arena.set($e * stride, ($e * 7 + 3).to_u32_wrap()) ?? $arena
        $e = $e + 1
    }
    $arena
}

cap_for = |slack, len| {
    match slack {
        Exact => len
        Half => len + (len / 2) + 2
        Pow2 => {
            var $c = 4.U64
            while $c < len { $c = $c * 2 }
            $c
        }
    }
}

# ---------------------------------------------------------------- scheme A: pool

# Build a fresh CSR pool from (per-literal counts, a source of entries).
# `emit(l, i)` semantics are inlined by the two callers below; this helper only
# lays out offsets and capacities and returns a zeroed pool of the right size.
layout = |l, lens, slack| {
    var $wofs = List.with_capacity(l)
    var $wcap = List.with_capacity(l)
    var $off = 1.U64 # word 0 reserved
    var $i = 0.U64
    while $i < l {
        len = lens.get($i)?.to_u64()
        cap = cap_for(slack, len)
        $wofs = $wofs.append($off.to_u32_wrap())
        $wcap = $wcap.append(cap.to_u32_wrap())
        $off = $off + (2 * cap)
        $i = $i + 1
    }
    (wofs, wcap, words) = ($wofs, $wcap, $off)
    Ok({ wofs, wcap, words })
}

run_pool = |l, t, r, stride, opts| {
    { elit, eblk, val } = gen_entries(l, t)
    arena = gen_arena(t, stride)

    # counts per literal
    var $lens = List.repeat(0.U32, l)
    var $e = 0.U64
    while $e < t {
        li = elit.get($e)?.to_u64()
        $lens = $lens.set(li, $lens.get(li)? + 1)?
        $e = $e + 1
    }
    { wofs, wcap, words } = layout(l, $lens, opts.slack)?
    var $wofs = wofs
    var $wcap = wcap
    var $wlen = List.repeat(0.U32, l)
    var $pool = List.repeat(0.U32, words)
    $e = 0
    while $e < t {
        li = elit.get($e)?.to_u64()
        n = $wlen.get(li)?.to_u64()
        j = $wofs.get(li)?.to_u64() + (2 * n)
        $pool = $pool.set(j, eblk.get($e)?)?
        $pool = $pool.set(j + 1, $e.to_u32_wrap())?
        $wlen = $wlen.set(li, (n + 1).to_u32_wrap())?
        $e = $e + 1
    }

    var $garbage = 0.U64
    var $touch = 0.U64
    var $moves = 0.U64
    var $relocs = 0.U64
    var $compacts = 0.U64
    var $rng = 1234567.U64
    var $step = 0.U64
    while $step < r {
        $rng = next_rng($rng)
        p = rng_below($rng, l)
        base = $wofs.get(p)?.to_u64()
        n = $wlen.get(p)?.to_u64()
        var $i = 0.U64
        var $k = 0.U64 # compaction cursor (entries kept)
        while $i < n {
            j = base + (2 * $i)
            blk = $pool.get(j)?
            cref = $pool.get(j + 1)?
            keep =
                if val.get(blk.to_u64())? == 1 {
                    Bool.True
                } else {
                    # blocker miss: visit the clause
                    $touch = $touch + arena.get(cref.to_u64() * stride)?.to_u64()
                    h = mix(cref, $step)
                    if h.bitwise_and(1) == 0 {
                        q = h.shr_wrap(1).to_u64() % l
                        if q == p {
                            Bool.True
                        } else {
                            # ---- push_watch(q, blk, cref)
                            qn = $wlen.get(q)?.to_u64()
                            qcap = $wcap.get(q)?.to_u64()
                            if qn == qcap {
                                newcap = (2 * qcap).max(4)
                                newofs = $pool.len()
                                oldofs = $wofs.get(q)?.to_u64()
                                if opts.manual_copy {
                                    var $w = 0.U64
                                    while $w < (2 * qn) {
                                        $pool = $pool.append($pool.get(oldofs + $w)?)
                                        $w = $w + 1
                                    }
                                    while $w < (2 * newcap) {
                                        $pool = $pool.append(0)
                                        $w = $w + 1
                                    }
                                } else {
                                    if qn > 0 {
                                        $pool = $pool.append_range_within(oldofs, 2 * qn)?
                                        # pad with copies of the live words (content is dead beyond wlen)
                                        $pool = $pool.append_range_within(newofs, 2 * (newcap - qn))?
                                    } else {
                                        var $w = 0.U64
                                        while $w < (2 * newcap) {
                                            $pool = $pool.append(0)
                                            $w = $w + 1
                                        }
                                    }
                                }
                                $garbage = $garbage + (2 * qcap)
                                $wofs = $wofs.set(q, newofs.to_u32_wrap())?
                                $wcap = $wcap.set(q, newcap.to_u32_wrap())?
                                $relocs = $relocs + 1
                            }
                            jq = $wofs.get(q)?.to_u64() + (2 * qn)
                            $pool = $pool.set(jq, blk)?
                            $pool = $pool.set(jq + 1, cref)?
                            $wlen = $wlen.set(q, (qn + 1).to_u32_wrap())?
                            $moves = $moves + 1
                            Bool.False
                        }
                    } else {
                        Bool.True
                    }
                }
            if keep {
                if $k != $i {
                    jk = base + (2 * $k)
                    $pool = $pool.set(jk, blk)?
                    $pool = $pool.set(jk + 1, cref)?
                }
                $k = $k + 1
            }
            $i = $i + 1
        }
        $wlen = $wlen.set(p, $k.to_u32_wrap())?

        # ---- compaction policy
        do_gc = (opts.gc and $garbage > ($pool.len() * 3 / 4) and $pool.len() > 262144)
        do_period = (opts.period > 0 and (($step + 1) % opts.period == 0))
        if do_gc or do_period {
            { wofs: nofs, wcap: ncap, words: nwords } = layout(l, $wlen, opts.slack)?
            var $np = List.repeat(0.U32, nwords)
            var $li = 0.U64
            while $li < l {
                src = $wofs.get($li)?.to_u64()
                dst = nofs.get($li)?.to_u64()
                cnt = 2 * $wlen.get($li)?.to_u64()
                var $w = 0.U64
                while $w < cnt {
                    $np = $np.set(dst + $w, $pool.get(src + $w)?)?
                    $w = $w + 1
                }
                $li = $li + 1
            }
            $pool = $np
            $wofs = nofs
            $wcap = ncap
            $garbage = 0
            $compacts = $compacts + 1
        }
        $step = $step + 1
    }

    var $ck = $moves
    var $li = 0.U64
    while $li < l {
        $ck = $ck + ($wlen.get($li)?.to_u64() * ($li + 1))
        $li = $li + 1
    }
    Ok({ checksum: $ck, touch: $touch, moves: $moves, relocs: $relocs, compacts: $compacts, words: $pool.len() })
}

# ---------------------------------------------------------------- scheme C: linked

nil = 4294967295.U32

run_linked = |l, t, r, stride| {
    { elit, eblk, val } = gen_entries(l, t)
    var $arena = gen_arena(t, stride)
    var $head = List.repeat(nil, l)
    var $e = 0.U64
    while $e < t {
        li = elit.get($e)?.to_u64()
        $arena = $arena.set(($e * stride) + 1, $head.get(li)?)?
        $arena = $arena.set(($e * stride) + 2, eblk.get($e)?)?
        $head = $head.set(li, $e.to_u32_wrap())?
        $e = $e + 1
    }

    var $touch = 0.U64
    var $moves = 0.U64
    var $rng = 1234567.U64
    var $step = 0.U64
    while $step < r {
        $rng = next_rng($rng)
        p = rng_below($rng, l)
        var $prev = nil
        var $cur = $head.get(p)?
        while $cur != nil {
            c = $cur.to_u64() * stride
            nx = $arena.get(c + 1)?
            blk = $arena.get(c + 2)?
            keep =
                if val.get(blk.to_u64())? == 1 {
                    Bool.True
                } else {
                    $touch = $touch + $arena.get(c)?.to_u64()
                    h = mix($cur, $step)
                    if h.bitwise_and(1) == 0 {
                        q = h.shr_wrap(1).to_u64() % l
                        if q == p {
                            Bool.True
                        } else {
                            # unlink from p
                            if $prev == nil {
                                $head = $head.set(p, nx)?
                            } else {
                                $arena = $arena.set(($prev.to_u64() * stride) + 1, nx)?
                            }
                            # push-front on q
                            $arena = $arena.set(c + 1, $head.get(q)?)?
                            $head = $head.set(q, $cur)?
                            $moves = $moves + 1
                            Bool.False
                        }
                    } else {
                        Bool.True
                    }
                }
            if keep {
                $prev = $cur
            }
            $cur = nx
        }
        $step = $step + 1
    }

    var $ck = $moves
    var $li = 0.U64
    while $li < l {
        var $cur = $head.get($li)?
        while $cur != nil {
            $ck = $ck + ($li + 1)
            $cur = $arena.get(($cur.to_u64() * stride) + 1)?
        }
        $li = $li + 1
    }
    Ok({ checksum: $ck, touch: $touch, moves: $moves, relocs: 0, compacts: 0, words: t * stride })
}

