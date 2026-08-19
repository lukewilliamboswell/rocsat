# The CDCL solver: clause input at level 0, the search loop (propagate, analyse, backjump,
# learn), model extraction and DRAT emission. Decision heuristic: EVSIDS with an activity heap,
# initially negative phase. No restarts, no clause deletion, no minimisation.
#
# `add_all` and `search` are the owner loops: they hold the unpacked state in `var`s and apply
# one list-level step per statement (see the shape rule in Core); `add_clauses` and `solve`
# unpack and repack the record around them.

import Core
import Propagate
import Analyze
import Branch
import Drat
import Model
import Dimacs
import Brute

Solver :: [].{
    new : U64, Bool -> Core.State
    new = |num_vars, proof_on| {
        st = Core.new(num_vars)
        { proof, .. } = st
        { ..st, proof: { ..proof, on: proof_on } }
    }

    from_cnf : Dimacs.Cnf, Bool -> Core.State
    from_cnf = |cnf, proof_on| add_clauses(new(cnf.num_vars, proof_on), cnf.clauses)

    # Adds clauses at decision level 0: duplicates removed, false literals dropped, tautologies
    # and satisfied clauses skipped, units propagated immediately. Once a conflict has been
    # found (`ok = false`) further clauses are ignored.
    add_clauses : Core.State, List(List(U32)) -> Core.State
    add_clauses = |st0, clauses| {
        { arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim, seen, activity, heap, hpos, search, stats, proof } = st0
        expect search.dl == 0
        (arena1, pool1, wofs1, wlen1, wcap1, value1, level1, reason1, trail1, bytes1, sc) =
            add_all(arena, pool, wofs, wlen, wcap, value, level, reason, trail, proof.bytes, { trail_len: search.trail_len, qhead: search.qhead, ok: search.ok, propagations: stats.propagations, proof_on: proof.on, traced: proof.traced }, clauses)
        {
            arena: arena1,
            pool: pool1,
            wofs: wofs1,
            wlen: wlen1,
            wcap: wcap1,
            value: value1,
            level: level1,
            reason: reason1,
            trail: trail1,
            trail_lim,
            seen,
            activity,
            heap,
            hpos,
            search: { ..search, trail_len: sc.trail_len, qhead: sc.qhead, ok: sc.ok },
            stats: { ..stats, propagations: sc.propagations },
            proof: { ..proof, bytes: bytes1, traced: sc.traced },
        }
    }

    AddScalars : { trail_len : U64, qhead : U64, ok : Bool, propagations : U64, proof_on : Bool, traced : U64 }

    add_all : List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), List(U8), AddScalars, List(List(U32)) -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), List(U8), AddScalars)
    add_all = |arena, pool, wofs, wlen, wcap, value, level, reason, trail, bytes, sc, clauses| {
        proof_on = sc.proof_on
        var $arena = arena
        var $pool = pool
        var $wofs = wofs
        var $wlen = wlen
        var $wcap = wcap
        var $value = value
        var $level = level
        var $reason = reason
        var $trail = trail
        var $trail_len = sc.trail_len
        var $qhead = sc.qhead
        var $ok = sc.ok
        var $props = sc.propagations
        var $bytes = bytes
        var $traced = sc.traced
        for lits in clauses {
            if $ok {
                match simplify($value, lits) {
                    Skip => {}
                    Keep(kept) => {
                        if proof_on and kept.len() != lits.len() and !kept.is_empty() {
                            added = Drat.add_clause($bytes, kept)
                            $bytes = Drat.delete_clause(added, lits)
                        }
                        match kept {
                            [] => {
                                $ok = Bool.False
                                if proof_on {
                                    $bytes = Drat.add_empty($bytes)
                                }
                            }
                            [unit] => {
                                (va, le, re, tr, tl) = Core.assign($value, $level, $reason, $trail, $trail_len, unit, Core.none, 0)
                                (a, p, wo, wl, wc, va1, le1, re1, tr1, tl1, q, props, confl) = Propagate.propagate($arena, $pool, $wofs, $wlen, $wcap, va, le, re, tr, tl, $qhead, 0, $props)
                                $arena = a
                                $pool = p
                                $wofs = wo
                                $wlen = wl
                                $wcap = wc
                                $value = va1
                                $level = le1
                                $reason = re1
                                $trail = tr1
                                $trail_len = tl1
                                $qhead = q
                                $props = props
                                if proof_on {
                                    (bytes2, traced) = trace_units($bytes, $trail, $trail_len, $traced)
                                    $bytes = bytes2
                                    $traced = traced
                                }
                                if confl != Core.none {
                                    $ok = Bool.False
                                    if proof_on {
                                        $bytes = Drat.add_empty($bytes)
                                    }
                                }
                            }
                            _ => {
                                (a, p, wo, wl, wc, _) = Core.learn($arena, $pool, $wofs, $wlen, $wcap, kept, Bool.False)
                                $arena = a
                                $pool = p
                                $wofs = wo
                                $wlen = wl
                                $wcap = wc
                                expect Core.watches_consistent($arena, $pool, $wofs, $wlen)
                            }
                        }
                    }
                }
            }
        }
        ($arena, $pool, $wofs, $wlen, $wcap, $value, $level, $reason, $trail, $bytes, { trail_len: $trail_len, qhead: $qhead, ok: $ok, propagations: $props, proof_on, traced: $traced })
    }

    # The clause as it stands at level 0: sorted, without duplicates and false literals;
    # `Skip` when it is tautological or already satisfied.
    simplify : List(U8), List(U32) -> [Skip, Keep(List(U32))]
    simplify = |value, lits| {
        sorted = lits.sort_with(|a, b| a.compare(b))
        var $kept = []
        var $prev = Core.undef_lit
        for q in sorted {
            val = value.get(q.to_u64()) ?? 0
            if q == $prev.bitwise_xor(1) or val == Model.true_val {
                return Skip
            }
            if q != $prev and val == Model.unassigned {
                $kept = $kept.append(q)
            }
            $prev = q
        }
        Keep($kept)
    }

    # Every level-0 trail literal from `traced` on becomes a unit lemma.
    trace_units : List(U8), List(U32), U64, U64 -> (List(U8), U64)
    trace_units = |bytes, trail, trail_len, traced| {
        var $bytes = bytes
        var $i = traced
        while $i < trail_len {
            $bytes = Drat.add_clause($bytes, [trail.get($i) ?? 0])
            $i = $i + 1
        }
        ($bytes, trail_len)
    }

    solve : Core.State -> (Core.State, [Sat, Unsat])
    solve = |st0| {
        { arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim, seen, activity, heap, hpos, search, stats, proof } = st0
        (arena1, pool1, wofs1, wlen1, wcap1, value1, level1, reason1, trail1, trail_lim1, seen1, activity1, heap1, hpos1, bytes1, sc, status) =
            search_loop(arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim, seen, activity, heap, hpos, proof.bytes, { trail_len: search.trail_len, dl: search.dl, qhead: search.qhead, heap_len: search.heap_len, var_inc: search.var_inc, ok: search.ok, conflicts: stats.conflicts, decisions: stats.decisions, propagations: stats.propagations, proof_on: proof.on, traced: proof.traced })
        st = {
            arena: arena1,
            pool: pool1,
            wofs: wofs1,
            wlen: wlen1,
            wcap: wcap1,
            value: value1,
            level: level1,
            reason: reason1,
            trail: trail1,
            trail_lim: trail_lim1,
            seen: seen1,
            activity: activity1,
            heap: heap1,
            hpos: hpos1,
            search: { trail_len: sc.trail_len, dl: sc.dl, qhead: sc.qhead, heap_len: sc.heap_len, var_inc: sc.var_inc, ok: sc.ok },
            stats: { conflicts: sc.conflicts, decisions: sc.decisions, propagations: sc.propagations },
            proof: { ..proof, bytes: bytes1, traced: sc.traced },
        }
        (st, status)
    }

    SearchScalars : { trail_len : U64, dl : U64, qhead : U64, heap_len : U64, var_inc : F64, ok : Bool, conflicts : U64, decisions : U64, propagations : U64, proof_on : Bool, traced : U64 }

    # The CDCL loop on the unpacked state.
    search_loop : List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), List(U32), List(U8), List(F64), List(U32), List(U32), List(U8), SearchScalars -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), List(U32), List(U8), List(F64), List(U32), List(U32), List(U8), SearchScalars, [Sat, Unsat])
    search_loop = |arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim, seen, activity, heap, hpos, bytes, sc| {
        num_vars = level.len()
        proof_on = sc.proof_on
        var $arena = arena
        var $pool = pool
        var $wofs = wofs
        var $wlen = wlen
        var $wcap = wcap
        var $value = value
        var $level = level
        var $reason = reason
        var $trail = trail
        var $trail_len = sc.trail_len
        var $trail_lim = trail_lim
        var $dl = sc.dl
        var $seen = seen
        var $activity = activity
        var $heap = heap
        var $hpos = hpos
        var $heap_len = sc.heap_len
        var $var_inc = sc.var_inc
        var $qhead = sc.qhead
        var $ok = sc.ok
        var $conflicts = sc.conflicts
        var $decisions = sc.decisions
        var $props = sc.propagations
        var $bytes = bytes
        var $traced = sc.traced
        var $status = if sc.ok { Unknown } else { Unsat }
        while $status == Unknown {
            dl = $dl.to_u32_wrap()
            (a, p, wo, wl, wc, va, le, re, tr, tl, q, props, confl) = Propagate.propagate($arena, $pool, $wofs, $wlen, $wcap, $value, $level, $reason, $trail, $trail_len, $qhead, dl, $props)
            $arena = a
            $pool = p
            $wofs = wo
            $wlen = wl
            $wcap = wc
            $value = va
            $level = le
            $reason = re
            $trail = tr
            $trail_len = tl
            $qhead = q
            $props = props
            if confl != Core.none {
                $conflicts = $conflicts + 1
                if $dl == 0 {
                    $ok = Bool.False
                    if proof_on {
                        $bytes = Drat.add_empty($bytes)
                    }
                    $status = Unsat
                } else {
                    (seen1, learnt, bt, touched) = Analyze.analyze($arena, $trail, $trail_len, $level, $reason, $seen, dl, confl)
                    $seen = seen1
                    (activity2, heap2, hpos2, var_inc2) = Branch.bump_all($activity, $heap, $hpos, touched, $var_inc)
                    $activity = activity2
                    $heap = heap2
                    $hpos = hpos2
                    $var_inc = var_inc2
                    old_trail_len = $trail_len
                    (va2, tl2, dl2, q2) = Core.cancel_until($value, $trail, $trail_len, $trail_lim, $dl, bt.to_u64())
                    (heap3, hpos3, heap_len3) = Branch.reinsert($activity, $heap, $hpos, $heap_len, $trail, tl2, old_trail_len)
                    $value = va2
                    $trail_len = tl2
                    $dl = dl2
                    $qhead = q2
                    $heap = heap3
                    $hpos = hpos3
                    $heap_len = heap_len3
                    if proof_on {
                        $bytes = Drat.add_clause($bytes, learnt)
                    }
                    asserting = learnt.get(0) ?? 0
                    if learnt.len() == 1 {
                        (va3, le3, re3, tr3, tl3) = Core.assign($value, $level, $reason, $trail, $trail_len, asserting, Core.none, 0)
                        $value = va3
                        $level = le3
                        $reason = re3
                        $trail = tr3
                        $trail_len = tl3
                    } else {
                        (a4, p4, wo4, wl4, wc4, cref) = Core.learn($arena, $pool, $wofs, $wlen, $wcap, learnt, Bool.True)
                        $arena = a4
                        $pool = p4
                        $wofs = wo4
                        $wlen = wl4
                        $wcap = wc4
                        (va3, le3, re3, tr3, tl3) = Core.assign($value, $level, $reason, $trail, $trail_len, asserting, cref, bt)
                        $value = va3
                        $level = le3
                        $reason = re3
                        $trail = tr3
                        $trail_len = tl3
                    }
                }
            } else {
                if $dl == 0 and proof_on {
                    (bytes2, traced) = trace_units($bytes, $trail, $trail_len, $traced)
                    $bytes = bytes2
                    $traced = traced
                }
                (heap3, hpos3, heap_len3, v) = Branch.pick($activity, $heap, $hpos, $heap_len, $value, num_vars)
                $heap = heap3
                $hpos = hpos3
                $heap_len = heap_len3
                if v < num_vars {
                    $trail_lim = Core.put($trail_lim, $dl, $trail_len.to_u32_wrap())
                    $dl = $dl + 1
                    $decisions = $decisions + 1
                    (va3, le3, re3, tr3, tl3) = Core.assign($value, $level, $reason, $trail, $trail_len, (2 * v + 1).to_u32_wrap(), Core.none, dl + 1)
                    $value = va3
                    $level = le3
                    $reason = re3
                    $trail = tr3
                    $trail_len = tl3
                } else {
                    $status = Sat
                }
            }
        }
        scalars = { trail_len: $trail_len, dl: $dl, qhead: $qhead, heap_len: $heap_len, var_inc: $var_inc, ok: $ok, conflicts: $conflicts, decisions: $decisions, propagations: $props, proof_on, traced: $traced }
        ($arena, $pool, $wofs, $wlen, $wcap, $value, $level, $reason, $trail, $trail_lim, $seen, $activity, $heap, $hpos, $bytes, scalars, if $status == Sat { Sat } else { Unsat })
    }

    # The assignment after a `Sat` result: every variable is assigned.
    model : Core.State -> Model.Assignment
    model = |st| {
        num_vars = st.level.len()
        var $assign = List.with_capacity(num_vars)
        var $v = 0
        while $v < num_vars {
            $assign = $assign.append(st.value.get(2 * $v) ?? Model.unassigned)
            $v = $v + 1
        }
        $assign
    }

    stats : Core.State -> Str
    stats = |st| "c conflicts=${st.stats.conflicts.to_str()} decisions=${st.stats.decisions.to_str()} propagations=${st.stats.propagations.to_str()}"

    solve_cnf : Dimacs.Cnf -> [Sat(Model.Assignment), Unsat]
    solve_cnf = |cnf| {
        (st, r) = solve(from_cnf(cnf, Bool.False))
        match r {
            Sat => Sat(model(st))
            Unsat => Unsat
        }
    }

    # The assigned prefix of the trail (tests and diagnostics).
    trail_of : Core.State -> List(U32)
    trail_of = |st| st.trail.take_first(st.search.trail_len)
}

# Units and level-0 propagation through add_clauses.
expect {
    st = Solver.from_cnf({ num_vars: 3, clauses: [[0], [1, 2], [3, 4]] }, Bool.False)
    st.search.ok and Solver.trail_of(st) == [0, 2, 4] and st.arena.len() == 1
}

# Duplicate literals, tautology, satisfied clause, falsified literals dropped.
expect {
    st = Solver.from_cnf({ num_vars: 3, clauses: [[0], [2, 3, 4], [1, 2, 2, 4], [1, 4], [4, 4]] }, Bool.False)
    st.search.ok and Solver.trail_of(st) == [0, 4] and st.arena.len() == 1 + 4 and (st.arena.get(1) ?? 0) == 2
}

# Level-0 conflict via units and via propagation.
expect {
    a = Solver.from_cnf({ num_vars: 1, clauses: [[0], [1]] }, Bool.False)
    b = Solver.from_cnf({ num_vars: 2, clauses: [[0, 2], [0, 3], [1]] }, Bool.False)
    c = Solver.from_cnf({ num_vars: 1, clauses: [[]] }, Bool.False)
    !a.search.ok and !b.search.ok and !c.search.ok
}

# A chain of implications propagates fully after one decision, and again after backtracking.
expect {
    st = Solver.from_cnf({ num_vars: 5, clauses: [[1, 2], [3, 4], [5, 6], [7, 8]] }, Bool.False)
    (v1, l1, r1, t1, n1) = Core.assign(st.value, st.level, st.reason, st.trail, 0, 0, Core.none, 1)
    (a2, p2, wo2, wl2, wc2, v2, l2, r2, t2, n2, q2, _, confl) = Propagate.propagate(st.arena, st.pool, st.wofs, st.wlen, st.wcap, v1, l1, r1, t1, n1, 0, 1, 0)
    (v3, n3, dl3, q3) = Core.cancel_until(v2, t2, n2, [0, 0, 0, 0, 0], 1, 0)
    (v4, l4, r4, t4, n4) = Core.assign(v3, l2, r2, t2, n3, 0, Core.none, 1)
    (_, _, _, _, _, _, _, _, t5, n5, _, _, confl5) = Propagate.propagate(a2, p2, wo2, wl2, wc2, v4, l4, r4, t4, n4, q3, 1, 0)
    confl == Core.none and t2.take_first(n2) == [0, 2, 4, 6, 8] and n3 == 0 and dl3 == 0 and q2 == 5 and confl5 == Core.none and t5.take_first(n5) == t2.take_first(n2)
}

# Watch relocation under propagation: many clauses watching one literal, all forced at once.
expect {
    clauses = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(|i| [1, 2 * i])
    st = Solver.from_cnf({ num_vars: 11, clauses }, Bool.False)
    (v1, l1, r1, t1, n1) = Core.assign(st.value, st.level, st.reason, st.trail, 0, 0, Core.none, 1)
    (a2, p2, wo2, wl2, _, _, _, _, _, n2, _, _, confl) = Propagate.propagate(st.arena, st.pool, st.wofs, st.wlen, st.wcap, v1, l1, r1, t1, n1, 0, 1, 0)
    confl == Core.none and n2 == 11 and Core.watches_consistent(a2, p2, wo2, wl2)
}

# MiniSat-paper conflict graph: decisions x1..x4 (levels 1..4) with a conflict at level 4;
# the 1-UIP clause and backjump level are known.
expect {
    # x1@1, x2@2, x3@3 decisions; level 4: x4 decision, x5 <- (¬x4 ∨ x5), x6 <- (¬x4 ∨ ¬x1 ∨ x6),
    # x7 <- (¬x5 ∨ ¬x6 ∨ x7), x8 <- (¬x7 ∨ ¬x2 ∨ x8), conflict (¬x7 ∨ ¬x8 ∨ ¬x3).
    # UIP is x7: learnt = ¬x7 ∨ ¬x3 ∨ ¬x2, backjump to level 3.
    lit : U32, Bool -> U32
    lit = |v, pos| 2 * (v - 1) + (if pos { 0 } else { 1 })
    clauses = [
        [lit(4, Bool.False), lit(5, Bool.True)],
        [lit(4, Bool.False), lit(1, Bool.False), lit(6, Bool.True)],
        [lit(5, Bool.False), lit(6, Bool.False), lit(7, Bool.True)],
        [lit(7, Bool.False), lit(2, Bool.False), lit(8, Bool.True)],
        [lit(7, Bool.False), lit(8, Bool.False), lit(3, Bool.False)],
    ]
    st = Solver.from_cnf({ num_vars: 8, clauses }, Bool.False)
    var $arena = st.arena
    var $pool = st.pool
    var $wofs = st.wofs
    var $wlen = st.wlen
    var $wcap = st.wcap
    var $value = st.value
    var $level = st.level
    var $reason = st.reason
    var $trail = st.trail
    var $trail_len = 0
    var $qhead = 0
    var $confl = Core.none
    var $d = 1
    while $d <= 4 {
        (v1, l1, r1, t1, n1) = Core.assign($value, $level, $reason, $trail, $trail_len, lit($d, Bool.True), Core.none, $d.to_u32_wrap())
        (a, p, wo, wl, wc, va, le, re, tr, tl, q, _, confl) = Propagate.propagate($arena, $pool, $wofs, $wlen, $wcap, v1, l1, r1, t1, n1, $qhead, $d.to_u32_wrap(), 0)
        $arena = a
        $pool = p
        $wofs = wo
        $wlen = wl
        $wcap = wc
        $value = va
        $level = le
        $reason = re
        $trail = tr
        $trail_len = tl
        $qhead = q
        if $d < 4 and confl != Core.none { $confl = 1 } else if $d == 4 { $confl = confl }
        $d = $d + 1
    }
    (seen, learnt, bt, touched) = Analyze.analyze($arena, $trail, $trail_len, $level, $reason, st.seen, 4, $confl)
    $confl != Core.none and $confl != 1
    and (learnt.get(0) ?? 0) == lit(7, Bool.False)
    and (learnt.get(1) ?? 0) == lit(3, Bool.False)
    and learnt.len() == 3
    and bt == 3
    and touched.len() == 4
    and seen.all(|s| s == 0)
}

expect Solver.solve_cnf({ num_vars: 0, clauses: [] }) == Sat([])
expect Solver.solve_cnf({ num_vars: 2, clauses: [] }) == Sat([2, 2])
expect Solver.solve_cnf({ num_vars: 0, clauses: [[]] }) == Unsat
expect Solver.solve_cnf({ num_vars: 2, clauses: [[0], [1]] }) == Unsat
expect Solver.solve_cnf({ num_vars: 2, clauses: [[0, 2], [0, 3], [1, 2], [1, 3]] }) == Unsat
expect Solver.solve_cnf({ num_vars: 3, clauses: [[0, 2], [1, 4], [3, 5]] }) == Sat([2, 1, 2])
expect Solver.solve_cnf({ num_vars: 3, clauses: [[0, 2, 4], [1, 2, 4], [0, 3, 4], [0, 2, 5], [1, 3, 4], [1, 2, 5], [0, 3, 5], [1, 3, 5]] }) == Unsat

# Differential against the brute-force reference on seeded random 8-var 3-CNFs.
expect {
    var $seed = 1
    var $ok = Bool.True
    while $seed <= 200 {
        cnf = Brute.random_cnf($seed, 8, 34)
        match (Solver.solve_cnf(cnf), Brute.solve(cnf)) {
            (Sat(a), Ok(Sat(_))) => if Model.satisfies(a, cnf) != Ok({}) { $ok = Bool.False }
            (Unsat, Ok(Unsat)) => {}
            _ => { $ok = Bool.False }
        }
        $seed = $seed + 1
    }
    $ok
}

# Watch invariants hold along an EVSIDS decision sequence on 200 seeded random CNFs. After every
# conflict-free propagation no clause is unit or falsified, every watch is in place, and the lazy
# activity heap remains consistent.
expect {
    var $seed = 1
    var $ok = Bool.True
    while $seed <= 200 {
        st = Solver.from_cnf(Brute.random_cnf($seed, 8, 34), Bool.False)
        var $arena = st.arena
        var $pool = st.pool
        var $wofs = st.wofs
        var $wlen = st.wlen
        var $wcap = st.wcap
        var $value = st.value
        var $level = st.level
        var $reason = st.reason
        var $trail = st.trail
        var $trail_len = st.search.trail_len
        var $activity = st.activity
        var $heap = st.heap
        var $hpos = st.hpos
        var $heap_len = st.search.heap_len
        var $qhead = st.search.qhead
        var $dl = 0
        var $go = st.search.ok
        while $go {
            (a, p, wo, wl, wc, va, le, re, tr, tl, q, _, confl) = Propagate.propagate($arena, $pool, $wofs, $wlen, $wcap, $value, $level, $reason, $trail, $trail_len, $qhead, $dl, 0)
            $arena = a
            $pool = p
            $wofs = wo
            $wlen = wl
            $wcap = wc
            $value = va
            $level = le
            $reason = re
            $trail = tr
            $trail_len = tl
            $qhead = q
            if confl != Core.none {
                $go = Bool.False
            } else {
                if !Propagate.no_pending_clause($arena, $value) or !Core.watches_consistent($arena, $pool, $wofs, $wlen) or !Branch.consistent($activity, $heap, $hpos, $heap_len) { $ok = Bool.False }
                (heap1, hpos1, heap_len1, v) = Branch.pick($activity, $heap, $hpos, $heap_len, $value, 8)
                $heap = heap1
                $hpos = hpos1
                $heap_len = heap_len1
                if v < 8 {
                    $dl = $dl + 1
                    (v1, l1, r1, t1, n1) = Core.assign($value, $level, $reason, $trail, $trail_len, (2 * v + 1).to_u32_wrap(), Core.none, $dl)
                    $value = v1
                    $level = l1
                    $reason = r1
                    $trail = t1
                    $trail_len = n1
                } else {
                    $go = Bool.False
                }
            }
        }
        $seed = $seed + 1
    }
    $ok
}
