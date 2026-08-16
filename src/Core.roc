# Solver state and the data-structure layer: clause arena, pooled watch lists, trail.
#
# Literals are `2*var + sign` (`lit ^ 1` negates); a clause reference `cref` is its offset in the
# arena, with `arena[0]` reserved so `cref = 0` means none. Clause layout: `[header, meta,
# lits...]`, header bits 0..27 = size, bit 28 = learnt, bit 29 = deleted; the two watched literals
# are the first two. Watch lists (scheme A): every literal owns a block of `wcap` two-word entries
# `[blocker, cref]` at `pool[wofs..]`, relocated to the end of the pool with doubled capacity when
# full; `pool[0]` is reserved so `wofs = 0` means no block yet.
#
# `trail` and `trail_lim` are fixed-capacity buffers (one slot per variable) with explicit
# lengths in `search`, so the solver never truncates a list: `List.drop_last`/`take_first`
# results are "maybe shared" to the compiler and any list that flows through them is copied on
# its next write.
#
# The `State` record exists at the API boundary only. Every function that mutates takes the
# lists it needs as separate parameters and returns them in a tuple, and the owner loops
# (`Solver.add_all`, `Solver.search_loop`) hold the lists in `var`s between calls. That is the
# one shape this compiler reliably keeps in place. Threading the record instead was measured to
# copy lists in every variant tried: a record parameter is borrowed for the whole call, so a
# callee that mutates one list and passes the rebuilt record on shares the other fields with the
# caller's copy; a record returned inside a tuple keeps the caller's old record alive; a
# projection read between destructure and rebuild, a conditional around the call in a loop, or
# more than 16 fields each break the field-take optimisation. List writes go through `put`.

import Model

Core :: [].{
    State : {
        arena : List(U32),
        pool : List(U32),
        wofs : List(U32),
        wlen : List(U32),
        wcap : List(U32),
        value : List(U8),
        level : List(U32),
        reason : List(U32),
        trail : List(U32),
        trail_lim : List(U32),
        seen : List(U8),
        search : Search,
        stats : Stats,
        proof : Proof,
    }

    # `trail_len` assigned literals, `dl` decision levels (`trail_lim[0..dl]` = trail index of each
    # level's decision), `qhead` = first unpropagated trail index, `next_var` = decision cursor
    # (lowest possibly unassigned variable), `ok` false once the formula is refuted.
    Search : { trail_len : U64, dl : U64, qhead : U64, next_var : U64, ok : Bool }

    Stats : { conflicts : U64, decisions : U64, propagations : U64 }

    # `traced` = number of level-0 trail literals already emitted as unit lemmas.
    Proof : { on : Bool, bytes : List(U8), traced : U64 }

    none : U32
    none = 0

    undef_lit : U32
    undef_lit = 0xFFFFFFFF

    size_mask : U32
    size_mask = 0x0FFFFFFF
    learnt_bit : U32
    learnt_bit = 0x10000000
    deleted_bit : U32
    deleted_bit = 0x20000000

    new : U64 -> State
    new = |n| {
        arena: [0],
        pool: [0],
        wofs: List.repeat(0, 2 * n),
        wlen: List.repeat(0, 2 * n),
        wcap: List.repeat(0, 2 * n),
        value: List.repeat(Model.unassigned, 2 * n),
        level: List.repeat(0, n),
        reason: List.repeat(none, n),
        trail: List.repeat(0, n),
        trail_lim: List.repeat(0, n),
        seen: List.repeat(0, n),
        search: { trail_len: 0, dl: 0, qhead: 0, next_var: 0, ok: Bool.True },
        stats: { conflicts: 0, decisions: 0, propagations: 0 },
        proof: { on: Bool.False, bytes: [], traced: 0 },
    }

    # In-place write; `list.set(i, x) ?? list` is the shape the compiler keeps in place both
    # inside small inlined helpers and inside large functions. An out-of-range index is a
    # solver bug and leaves the list unchanged.
    put : List(a), U64, a -> List(a)
    put = |list, i, x| {
        expect i < list.len()
        list.set(i, x) ?? list
    }

    clause_size : U32 -> U64
    clause_size = |header| header.bitwise_and(size_mask).to_u64()

    # Assigns `lit` true at decision level `dl` with reason `from`, appending it to the trail.
    # `lit` must be unassigned.
    assign : List(U8), List(U32), List(U32), List(U32), U64, U32, U32, U32 -> (List(U8), List(U32), List(U32), List(U32), U64)
    assign = |value, level, reason, trail, trail_len, lit, from, dl| {
        expect (value.get(lit.to_u64()) ?? 0) == Model.unassigned
        v = lit.shr_wrap(1).to_u64()
        value1 = put(value, lit.to_u64(), Model.true_val)
        value2 = put(value1, lit.bitwise_xor(1).to_u64(), Model.false_val)
        (value2, put(level, v, dl), put(reason, v, from), put(trail, trail_len, lit), trail_len + 1)
    }

    # Undoes every assignment above decision level `lvl`: returns `value`, the new trail
    # length, the new decision level and `qhead` (literals at levels <= lvl stay propagated).
    cancel_until : List(U8), List(U32), U64, List(U32), U64, U64 -> (List(U8), U64, U64, U64)
    cancel_until = |value, trail, trail_len, trail_lim, dl, lvl| {
        start = if dl > lvl { (trail_lim.get(lvl) ?? 0).to_u64() } else { trail_len }
        var $value = value
        var $i = trail_len
        while $i > start {
            $i = $i - 1
            lit = (trail.get($i) ?? 0).to_u64()
            $value = put($value, lit, Model.unassigned)
            $value = put($value, lit.bitwise_xor(1), Model.unassigned)
        }
        ($value, start, dl.min(lvl), start)
    }

    # Appends a clause of size >= 2 to the arena and returns its cref.
    alloc : List(U32), List(U32), Bool -> (List(U32), U32)
    alloc = |arena, lits, learnt| {
        expect lits.len() >= 2
        cref = arena.len().to_u32_wrap()
        header = lits.len().to_u32_wrap().bitwise_or(if learnt { learnt_bit } else { 0 })
        (arena.append(header).append(0).concat(lits), cref)
    }

    push_watch : List(U32), List(U32), List(U32), List(U32), U32, U32, U32 -> (List(U32), List(U32), List(U32), List(U32))
    push_watch = |pool, wofs, wlen, wcap, lit, blocker, cref| {
        l = lit.to_u64()
        n = (wlen.get(l) ?? 0).to_u64()
        cap = (wcap.get(l) ?? 0).to_u64()
        (pool1, wofs1, wcap1) =
            if n == cap {
                newcap = (2 * cap).max(4)
                newofs = pool.len()
                oldofs = (wofs.get(l) ?? 0).to_u64()
                grown =
                    if n > 0 {
                        live = pool.append_range_within(oldofs, 2 * n) ?? pool
                        live.append_range_within(newofs, 2 * (newcap - n)) ?? live
                    } else {
                        pool.concat(List.repeat(0, 2 * newcap))
                    }
                (grown, put(wofs, l, newofs.to_u32_wrap()), put(wcap, l, newcap.to_u32_wrap()))
            } else {
                (pool, wofs, wcap)
            }
        j = (wofs1.get(l) ?? 0).to_u64() + 2 * n
        pool2 = put(pool1, j, blocker)
        (put(pool2, j + 1, cref), wofs1, put(wlen, l, (n + 1).to_u32_wrap()), wcap1)
    }

    # Stores a clause of size >= 2 in the arena and watches its first two literals.
    learn : List(U32), List(U32), List(U32), List(U32), List(U32), List(U32), Bool -> (List(U32), List(U32), List(U32), List(U32), List(U32), U32)
    learn = |arena, pool, wofs, wlen, wcap, lits, learnt| {
        (arena1, cref) = alloc(arena, lits, learnt)
        l0 = lits.get(0) ?? 0
        l1 = lits.get(1) ?? 0
        (pool1, wofs1, wlen1, wcap1) = push_watch(pool, wofs, wlen, wcap, l0.bitwise_xor(1), l1, cref)
        (pool2, wofs2, wlen2, wcap2) = push_watch(pool1, wofs1, wlen1, wcap1, l1.bitwise_xor(1), l0, cref)
        (arena1, pool2, wofs2, wlen2, wcap2, cref)
    }

    # Watch invariant A1: the two watched literals of every live clause are its first two, each
    # present exactly once in the block of its negation. O(arena + pool); for `expect` bodies only.
    watches_consistent : List(U32), List(U32), List(U32), List(U32) -> Bool
    watches_consistent = |arena, pool, wofs, wlen| {
        var $c = 1
        var $ok = Bool.True
        while $c < arena.len() {
            header = arena.get($c) ?? 0
            size = clause_size(header)
            if header.bitwise_and(deleted_bit) == 0 {
                l0 = arena.get($c + 2) ?? 0
                l1 = arena.get($c + 3) ?? 0
                if count_watch(pool, wofs, wlen, l0.bitwise_xor(1), $c.to_u32_wrap()) != 1 { $ok = Bool.False }
                if count_watch(pool, wofs, wlen, l1.bitwise_xor(1), $c.to_u32_wrap()) != 1 { $ok = Bool.False }
            }
            $c = $c + 2 + size
        }
        $ok
    }

    count_watch : List(U32), List(U32), List(U32), U32, U32 -> U64
    count_watch = |pool, wofs, wlen, lit, cref| {
        base = (wofs.get(lit.to_u64()) ?? 0).to_u64()
        n = (wlen.get(lit.to_u64()) ?? 0).to_u64()
        var $i = 0
        var $count = 0
        while $i < n {
            if (pool.get(base + 2 * $i + 1) ?? 0) == cref { $count = $count + 1 }
            $i = $i + 1
        }
        $count
    }
}

expect {
    st = Core.new(3)
    st.value.len() == 6 and st.search.trail_len == 0 and st.search.dl == 0 and st.search.ok
}

expect {
    st = Core.new(3)
    (value1, level1, reason1, trail1, len1) = Core.assign(st.value, st.level, st.reason, st.trail, 0, 2, Core.none, 0)
    (value2, level2, _, trail2, len2) = Core.assign(value1, level1, reason1, trail1, len1, 5, Core.none, 1)
    (value3, len3, dl3, qhead3) = Core.cancel_until(value2, trail2, len2, [1, 0, 0], 1, 0)
    (value1.get(2) ?? 0) == Model.true_val
    and (value1.get(3) ?? 0) == Model.false_val
    and trail2.take_first(len2) == [2, 5]
    and (level2.get(2) ?? 9) == 1
    and len3 == 1
    and dl3 == 0
    and (value3.get(5) ?? 9) == Model.unassigned
    and (value3.get(4) ?? 9) == Model.unassigned
    and qhead3 == 1
}

# Relocation: 5 clauses watching the same literal overflow the initial block of 4 entries.
expect {
    st = Core.new(6)
    var $arena = st.arena
    var $pool = st.pool
    var $wofs = st.wofs
    var $wlen = st.wlen
    var $wcap = st.wcap
    var $i = 1
    while $i <= 5 {
        (a, p, wo, wl, wc, _) = Core.learn($arena, $pool, $wofs, $wlen, $wcap, [0, (2 * $i).to_u32_wrap()], Bool.False)
        $arena = a
        $pool = p
        $wofs = wo
        $wlen = wl
        $wcap = wc
        $i = $i + 1
    }
    (($wlen.get(1) ?? 0) == 5) and (($wcap.get(1) ?? 0) == 8) and Core.watches_consistent($arena, $pool, $wofs, $wlen)
}
