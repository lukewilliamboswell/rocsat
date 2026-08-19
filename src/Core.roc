# Solver state and the data-structure layer: clause arena, pooled watch lists, trail.
#
# Literals are `2*var + sign` (`lit ^ 1` negates); a clause reference `cref` is its offset in the
# arena, with `arena[0]` reserved so `cref = 0` means none. Clause layout: `[header, meta,
# lits...]`, header bits 0..27 = size, bit 28 = learnt, bit 29 = deleted; meta bits 0..7 =
# saturating LBD and bits 8..9 = use age. The two watched literals
# are the first two. Watch lists (scheme A): every literal owns a block of `wcap` two-word entries
# `[blocker, cref]` at `pool[wofs..]`, relocated to the end of the pool with doubled capacity when
# full; `pool[0]` is reserved so `wofs = 0` means no block yet.
#
# `trail`, `trail_lim`, and the variable heap are fixed-capacity buffers (one slot per variable)
# with explicit live lengths. This keeps the established hot loops on indexed writes; an earlier
# claim that truncating a list poisons uniqueness no longer reproduces on the pinned compiler.
#
# The `State` record exists at the API boundary only. Every function that mutates takes the
# lists it needs as separate parameters and returns them in a tuple, and the owner loops
# (`Solver.add_all`, `Solver.search_loop`) hold the lists in `var`s between calls. That is the
# one shape this compiler reliably keeps in place. Threading the record instead was measured to
# copy lists in the solver's call shapes: a record parameter is borrowed for the whole call, so a
# callee that mutates one list and passes the rebuilt record on shares the other fields with the
# caller's copy; a record returned inside a tuple keeps the caller's old record alive. List writes
# go through `put`.

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
        activity : List(F64),
        heap : List(U32),
        hpos : List(U32),
        phase : List(U8),
        search : Search,
        stats : Stats,
        proof : Proof,
    }

    # `trail_len` assigned literals, `dl` decision levels (`trail_lim[0..dl]` = trail index of each
    # level's decision), `qhead` = first unpropagated trail index. `heap_len` is the live prefix of
    # the fixed-capacity EVSIDS heap; `var_inc` is the next activity bump amount; `simplified` is
    # the root-trail length consumed by the last level-0 simplification.
    Search : { trail_len : U64, dl : U64, qhead : U64, heap_len : U64, var_inc : F64, simplified : U64, ok : Bool }

    Stats : { conflicts : U64, decisions : U64, propagations : U64, restarts : U64, reductions : U64, collections : U64, simplifications : U64, simplified_clauses : U64, simplified_literals : U64, deleted_clauses : U64, learnt_literals_before : U64, learnt_literals_after : U64 }

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
    glue_mask : U32
    glue_mask = 0x000000FF
    used_mask : U32
    used_mask = 0x00000300

    new : U64 -> State
    new = |n| {
        var $heap = List.with_capacity(n)
        var $hpos = List.with_capacity(n)
        var $v = 0
        while $v < n {
            $heap = $heap.append($v.to_u32_wrap())
            $hpos = $hpos.append($v.to_u32_wrap())
            $v = $v + 1
        }
        {
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
            activity: List.repeat(0, n),
            heap: $heap,
            hpos: $hpos,
            phase: List.repeat(1, n),
            search: { trail_len: 0, dl: 0, qhead: 0, heap_len: n, var_inc: 1.0, simplified: 0, ok: Bool.True },
            stats: { conflicts: 0, decisions: 0, propagations: 0, restarts: 0, reductions: 0, collections: 0, simplifications: 0, simplified_clauses: 0, simplified_literals: 0, deleted_clauses: 0, learnt_literals_before: 0, learnt_literals_after: 0 },
            proof: { on: Bool.False, bytes: [], traced: 0 },
        }
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

    clause_lits : List(U32), U32 -> List(U32)
    clause_lits = |arena, cref| {
        c = cref.to_u64()
        size = clause_size(arena.get(c) ?? 0)
        var $lits = List.with_capacity(size)
        var $i = 0
        while $i < size {
            $lits = $lits.append(arena.get(c + 2 + $i) ?? 0)
            $i = $i + 1
        }
        $lits
    }

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

    # Appends a clause of size >= 2 to the arena and returns its cref. Learned clauses store
    # saturating LBD in meta bits 0..7 and start with one use in bits 8..9.
    alloc : List(U32), List(U32), Bool, U32 -> (List(U32), U32)
    alloc = |arena, lits, learnt, glue| {
        expect lits.len() >= 2
        cref = arena.len().to_u32_wrap()
        header = lits.len().to_u32_wrap().bitwise_or(if learnt { learnt_bit } else { 0 })
        meta = if learnt { glue.min(255).bitwise_or(0x00000100) } else { 0 }
        (arena.append(header).append(meta).concat(lits), cref)
    }

    clause_glue : U32 -> U32
    clause_glue = |meta| meta.bitwise_and(glue_mask)

    clause_used : U32 -> U32
    clause_used = |meta| meta.bitwise_and(used_mask).shr_wrap(8)

    # Learned clauses participating in conflict derivation get the maximum use age.
    mark_used : List(U32), U32 -> List(U32)
    mark_used = |arena, cref| {
        c = cref.to_u64()
        header = arena.get(c) ?? 0
        if header.bitwise_and(learnt_bit) == 0 {
            arena
        } else {
            meta = arena.get(c + 1) ?? 0
            put(arena, c + 1, meta.bitwise_and(glue_mask).bitwise_or(used_mask))
        }
    }

    mark_used_all : List(U32), List(U32) -> List(U32)
    mark_used_all = |arena, crefs| {
        var $arena = arena
        for cref in crefs { $arena = mark_used($arena, cref) }
        $arena
    }

    age_clause : List(U32), U32 -> List(U32)
    age_clause = |arena, cref| {
        c = cref.to_u64()
        meta = arena.get(c + 1) ?? 0
        used = clause_used(meta)
        if used == 0 { arena } else { put(arena, c + 1, clause_glue(meta).bitwise_or((used - 1).shl_wrap(8))) }
    }

    mark_deleted : List(U32), U32 -> List(U32)
    mark_deleted = |arena, cref| {
        c = cref.to_u64()
        put(arena, c, (arena.get(c) ?? 0).bitwise_or(deleted_bit))
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
    learn : List(U32), List(U32), List(U32), List(U32), List(U32), List(U32), Bool, U32 -> (List(U32), List(U32), List(U32), List(U32), List(U32), U32)
    learn = |arena, pool, wofs, wlen, wcap, lits, learnt, glue| {
        (arena1, cref) = alloc(arena, lits, learnt, glue)
        l0 = lits.get(0) ?? 0
        l1 = lits.get(1) ?? 0
        (pool1, wofs1, wlen1, wcap1) = push_watch(pool, wofs, wlen, wcap, l0.bitwise_xor(1), l1, cref)
        (pool2, wofs2, wlen2, wcap2) = push_watch(pool1, wofs1, wlen1, wcap1, l1.bitwise_xor(1), l0, cref)
        (arena1, pool2, wofs2, wlen2, wcap2, cref)
    }

    # Rebuilds every live clause's watches into fresh pooled blocks, discarding relocation slack
    # and all watchers of deleted clauses.
    rebuild_watches : List(U32), U64 -> (List(U32), List(U32), List(U32), List(U32))
    rebuild_watches = |arena, num_lits| {
        var $pool = [0]
        var $wofs = List.repeat(0, num_lits)
        var $wlen = List.repeat(0, num_lits)
        var $wcap = List.repeat(0, num_lits)
        var $c = 1
        while $c < arena.len() {
            header = arena.get($c) ?? 0
            size = clause_size(header)
            if header.bitwise_and(deleted_bit) == 0 {
                l0 = arena.get($c + 2) ?? 0
                l1 = arena.get($c + 3) ?? 0
                (p1, wo1, wl1, wc1) = push_watch($pool, $wofs, $wlen, $wcap, l0.bitwise_xor(1), l1, $c.to_u32_wrap())
                (p2, wo2, wl2, wc2) = push_watch(p1, wo1, wl1, wc1, l1.bitwise_xor(1), l0, $c.to_u32_wrap())
                $pool = p2
                $wofs = wo2
                $wlen = wl2
                $wcap = wc2
            }
            $c = $c + 2 + size
        }
        ($pool, $wofs, $wlen, $wcap)
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
    st.value.len() == 6 and st.phase == [1, 1, 1] and st.search.trail_len == 0 and st.search.dl == 0 and st.search.ok
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
        (a, p, wo, wl, wc, _) = Core.learn($arena, $pool, $wofs, $wlen, $wcap, [0, (2 * $i).to_u32_wrap()], Bool.False, 0)
        $arena = a
        $pool = p
        $wofs = wo
        $wlen = wl
        $wcap = wc
        $i = $i + 1
    }
    (($wlen.get(1) ?? 0) == 5) and (($wcap.get(1) ?? 0) == 8) and Core.watches_consistent($arena, $pool, $wofs, $wlen)
}
