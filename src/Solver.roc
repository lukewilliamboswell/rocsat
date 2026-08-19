# The CDCL solver: clause input at level 0, the search loop (propagate, analyse, backjump,
# learn), model extraction and DRAT emission. Decision heuristic: EVSIDS with an activity heap
# and full phase saving, with Luby restarts, recursive learned-clause minimisation, LBD tiers,
# learned-clause reduction, watch rebuilds, and compacting arena collection.
#
# `add_all` and `search` are the owner loops: they hold the unpacked state in `var`s and apply
# one list-level step per statement (see the shape rule in Core); `add_clauses` and `solve`
# normalize, unpack, and repack the record around them.

import Core
import Propagate
import Analyze
import Reduce
import Simplify
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

    # Restores the level-0 input state before another solve or clause addition while retaining the
    # SAT assignment long enough for callers to inspect it.
    to_root : Core.State -> Core.State
    to_root = |st| {
        if st.search.dl == 0 {
            st
        } else {
            old_trail_len = st.search.trail_len
            (value, trail_len, dl, qhead) = Core.cancel_until(st.value, st.trail, old_trail_len, st.trail_lim, st.search.dl, 0)
            (heap, hpos, phase, heap_len) = Branch.backtrack(st.activity, st.heap, st.hpos, st.search.heap_len, st.phase, st.trail, trail_len, old_trail_len)
            { ..st, value, heap, hpos, phase, search: { ..st.search, trail_len, dl, qhead, heap_len } }
        }
    }

    # Adds clauses at decision level 0: duplicates removed, false literals dropped, tautologies
    # and satisfied clauses skipped, units propagated immediately. Once a conflict has been
    # found (`ok = false`) further clauses are ignored.
    add_clauses : Core.State, List(List(U32)) -> Core.State
    add_clauses = |input, clauses| {
        st0 = to_root(input)
        { arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim, seen, activity, heap, hpos, phase, search, stats, proof } = st0
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
            phase,
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
                                (a, p, wo, wl, wc, _) = Core.learn($arena, $pool, $wofs, $wlen, $wcap, kept, Bool.False, 0)
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

    solve : Core.State, List(U32) -> (Core.State, [Sat, Unsat], List(U32))
    solve = |input, assumptions| {
        rooted = to_root(input)
        { arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim: old_trail_lim, seen, activity, heap, hpos, phase, search, stats, proof } = rooted
        needed_levels = level.len() + assumptions.len()
        trail_lim = if old_trail_lim.len() < needed_levels { old_trail_lim.concat(List.repeat(0, needed_levels - old_trail_lim.len())) } else { old_trail_lim }
        (arena1, pool1, wofs1, wlen1, wcap1, value1, level1, reason1, trail1, trail_lim1, seen1, activity1, heap1, hpos1, phase1, bytes1, sc, status, final) =
            search_loop(arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim, seen, activity, heap, hpos, phase, proof.bytes, { trail_len: search.trail_len, dl: search.dl, qhead: search.qhead, heap_len: search.heap_len, var_inc: search.var_inc, simplified: search.simplified, ok: search.ok, conflicts: stats.conflicts, decisions: stats.decisions, propagations: stats.propagations, restarts: stats.restarts, reductions: stats.reductions, collections: stats.collections, simplifications: stats.simplifications, simplified_clauses: stats.simplified_clauses, simplified_literals: stats.simplified_literals, deleted_clauses: stats.deleted_clauses, learnt_literals_before: stats.learnt_literals_before, learnt_literals_after: stats.learnt_literals_after, proof_on: proof.on, traced: proof.traced }, assumptions)
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
            phase: phase1,
            search: { trail_len: sc.trail_len, dl: sc.dl, qhead: sc.qhead, heap_len: sc.heap_len, var_inc: sc.var_inc, simplified: sc.simplified, ok: sc.ok },
            stats: { conflicts: sc.conflicts, decisions: sc.decisions, propagations: sc.propagations, restarts: sc.restarts, reductions: sc.reductions, collections: sc.collections, simplifications: sc.simplifications, simplified_clauses: sc.simplified_clauses, simplified_literals: sc.simplified_literals, deleted_clauses: sc.deleted_clauses, learnt_literals_before: sc.learnt_literals_before, learnt_literals_after: sc.learnt_literals_after },
            proof: { ..proof, bytes: bytes1, traced: sc.traced },
        }
        (st, status, final)
    }

    SearchScalars : { trail_len : U64, dl : U64, qhead : U64, heap_len : U64, var_inc : F64, simplified : U64, ok : Bool, conflicts : U64, decisions : U64, propagations : U64, restarts : U64, reductions : U64, collections : U64, simplifications : U64, simplified_clauses : U64, simplified_literals : U64, deleted_clauses : U64, learnt_literals_before : U64, learnt_literals_after : U64, proof_on : Bool, traced : U64 }

    restart_first : U64
    restart_first = 1000

    # The CDCL loop on the unpacked state.
    search_loop : List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), List(U32), List(U8), List(F64), List(U32), List(U32), List(U8), List(U8), SearchScalars, List(U32) -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), List(U32), List(U8), List(F64), List(U32), List(U32), List(U8), List(U8), SearchScalars, [Sat, Unsat], List(U32))
    search_loop = |arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_lim, seen, activity, heap, hpos, phase, bytes, sc, assumptions| {
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
        var $phase = phase
        var $heap_len = sc.heap_len
        var $var_inc = sc.var_inc
        var $simplified = sc.simplified
        var $qhead = sc.qhead
        var $ok = sc.ok
        var $conflicts = sc.conflicts
        var $decisions = sc.decisions
        var $props = sc.propagations
        var $restarts = sc.restarts
        var $reductions = sc.reductions
        var $collections = sc.collections
        var $simplifications = sc.simplifications
        var $simplified_clauses = sc.simplified_clauses
        var $simplified_literals = sc.simplified_literals
        var $deleted_clauses = sc.deleted_clauses
        var $live_learnts = Reduce.counts(arena).learnt
        var $next_reduce = (($conflicts / 2000) + 1) * 2000
        var $learnt_literals_before = sc.learnt_literals_before
        var $learnt_literals_after = sc.learnt_literals_after
        var $restart_conflicts = 0
        var $restart_limit = restart_first * luby(2, sc.restarts)
        var $bytes = bytes
        var $traced = sc.traced
        var $final = []
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
                $restart_conflicts = $restart_conflicts + 1
                if $dl == 0 {
                    $ok = Bool.False
                    if proof_on {
                        $bytes = Drat.add_empty($bytes)
                    }
                    $status = Unsat
                } else {
                    (seen1, learnt, bt, touched, used_clauses, before, glue) = Analyze.analyze($arena, $trail, $trail_len, $trail_lim, $level, $reason, $seen, dl, confl)
                    $seen = seen1
                    $arena = Core.mark_used_all($arena, used_clauses)
                    $learnt_literals_before = $learnt_literals_before + before
                    $learnt_literals_after = $learnt_literals_after + learnt.len()
                    (activity2, heap2, hpos2, var_inc2) = Branch.bump_all($activity, $heap, $hpos, touched, $var_inc)
                    $activity = activity2
                    $heap = heap2
                    $hpos = hpos2
                    $var_inc = var_inc2
                    old_trail_len = $trail_len
                    (va2, tl2, dl2, q2) = Core.cancel_until($value, $trail, $trail_len, $trail_lim, $dl, bt.to_u64())
                    (heap3, hpos3, phase3, heap_len3) = Branch.backtrack($activity, $heap, $hpos, $heap_len, $phase, $trail, tl2, old_trail_len)
                    $value = va2
                    $trail_len = tl2
                    $dl = dl2
                    $qhead = q2
                    $heap = heap3
                    $hpos = hpos3
                    $phase = phase3
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
                        (a4, p4, wo4, wl4, wc4, cref) = Core.learn($arena, $pool, $wofs, $wlen, $wcap, learnt, Bool.True, glue)
                        $arena = a4
                        $pool = p4
                        $wofs = wo4
                        $wlen = wl4
                        $wcap = wc4
                        $live_learnts = $live_learnts + 1
                        (va3, le3, re3, tr3, tl3) = Core.assign($value, $level, $reason, $trail, $trail_len, asserting, cref, bt)
                        $value = va3
                        $level = le3
                        $reason = re3
                        $trail = tr3
                        $trail_len = tl3
                    }
                }
            } else {
                if $restart_conflicts >= $restart_limit {
                    old_trail_len = $trail_len
                    (va2, tl2, dl2, q2) = Core.cancel_until($value, $trail, $trail_len, $trail_lim, $dl, 0)
                    (heap3, hpos3, phase3, heap_len3) = Branch.backtrack($activity, $heap, $hpos, $heap_len, $phase, $trail, tl2, old_trail_len)
                    $value = va2
                    $trail_len = tl2
                    $dl = dl2
                    $qhead = q2
                    $heap = heap3
                    $hpos = hpos3
                    $phase = phase3
                    $heap_len = heap_len3
                    $restarts = $restarts + 1
                    $restart_conflicts = 0
                    $restart_limit = restart_first * luby(2, $restarts)
                    expect Branch.consistent($activity, $heap, $hpos, $heap_len)
                } else {
                    if $dl == 0 and proof_on {
                        (bytes2, traced) = trace_units($bytes, $trail, $trail_len, $traced)
                        $bytes = bytes2
                        $traced = traced
                    }
                    due_simplify = $dl == 0 and $trail_len > $simplified
                    (a5, p5, wo5, wl5, wc5, reason5, bytes5, removed, trimmed, live5, simplified5) = Simplify.maybe($arena, $pool, $wofs, $wlen, $wcap, $value, $reason, $trail, $trail_len, $bytes, proof_on, due_simplify, $live_learnts)
                    $arena = a5
                    $pool = p5
                    $wofs = wo5
                    $wlen = wl5
                    $wcap = wc5
                    $reason = reason5
                    $bytes = bytes5
                    $live_learnts = live5
                    if due_simplify {
                        $simplified = $trail_len
                        $simplifications = $simplifications + simplified5
                        $simplified_clauses = $simplified_clauses + removed
                        $simplified_literals = $simplified_literals + trimmed
                    }
                    due_reduce = $conflicts >= $next_reduce
                    (a6, p6, wo6, wl6, wc6, reason6, bytes6, deleted, live6, collected) = Reduce.maybe($arena, $pool, $wofs, $wlen, $wcap, $value, $reason, $bytes, proof_on, due_reduce, $live_learnts)
                    $arena = a6
                    $pool = p6
                    $wofs = wo6
                    $wlen = wl6
                    $wcap = wc6
                    $reason = reason6
                    $bytes = bytes6
                    $live_learnts = live6
                    if due_reduce {
                        $reductions = $reductions + 1
                        $collections = $collections + collected
                        $deleted_clauses = $deleted_clauses + deleted
                        $next_reduce = $next_reduce + 2000
                    }
                    var $made_assumption = Bool.False
                    while $dl < assumptions.len() and !$made_assumption and $status == Unknown {
                        assumption = assumptions.get($dl) ?? 0
                        val = $value.get(assumption.to_u64()) ?? Model.unassigned
                        if val == Model.false_val {
                            (seen7, final7) = Analyze.final($arena, $trail, $trail_len, $trail_lim, $level, $reason, $seen, assumption.bitwise_xor(1))
                            $seen = seen7
                            $final = final7
                            $status = Unsat
                        } else {
                            $trail_lim = Core.put($trail_lim, $dl, $trail_len.to_u32_wrap())
                            $dl = $dl + 1
                            if val == Model.unassigned {
                                $decisions = $decisions + 1
                                (va7, le7, re7, tr7, tl7) = Core.assign($value, $level, $reason, $trail, $trail_len, assumption, Core.none, $dl.to_u32_wrap())
                                $value = va7
                                $level = le7
                                $reason = re7
                                $trail = tr7
                                $trail_len = tl7
                                $made_assumption = Bool.True
                            }
                        }
                    }
                    if $status == Unknown and !$made_assumption {
                        (heap3, hpos3, heap_len3, v) = Branch.pick($activity, $heap, $hpos, $heap_len, $value, num_vars)
                        $heap = heap3
                        $hpos = hpos3
                        $heap_len = heap_len3
                        if v < num_vars {
                            $trail_lim = Core.put($trail_lim, $dl, $trail_len.to_u32_wrap())
                            $dl = $dl + 1
                            $decisions = $decisions + 1
                            sign = ($phase.get(v) ?? 1).to_u64()
                            (va3, le3, re3, tr3, tl3) = Core.assign($value, $level, $reason, $trail, $trail_len, (2 * v + sign).to_u32_wrap(), Core.none, $dl.to_u32_wrap())
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
            }
        }
        scalars = { trail_len: $trail_len, dl: $dl, qhead: $qhead, heap_len: $heap_len, var_inc: $var_inc, simplified: $simplified, ok: $ok, conflicts: $conflicts, decisions: $decisions, propagations: $props, restarts: $restarts, reductions: $reductions, collections: $collections, simplifications: $simplifications, simplified_clauses: $simplified_clauses, simplified_literals: $simplified_literals, deleted_clauses: $deleted_clauses, learnt_literals_before: $learnt_literals_before, learnt_literals_after: $learnt_literals_after, proof_on, traced: $traced }
        ($arena, $pool, $wofs, $wlen, $wcap, $value, $level, $reason, $trail, $trail_lim, $seen, $activity, $heap, $hpos, $phase, $bytes, scalars, if $status == Sat { Sat } else { Unsat }, $final)
    }

    # `1,1,2,1,1,2,4,...` for `y = 2`.
    luby : U64, U64 -> U64
    luby = |y, x0| {
        var $size = 1
        var $seq = 0
        while $size < x0 + 1 {
            $seq = $seq + 1
            $size = 2 * $size + 1
        }
        var $x = x0
        while $size - 1 != $x {
            $size = ($size - 1) / 2
            $seq = $seq - 1
            $x = $x % $size
        }
        var $result = 1
        var $i = 0
        while $i < $seq {
            $result = $result * y
            $i = $i + 1
        }
        $result
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
    stats = |st| {
        db = Reduce.counts(st.arena)
        "c conflicts=${st.stats.conflicts.to_str()} decisions=${st.stats.decisions.to_str()} propagations=${st.stats.propagations.to_str()} restarts=${st.stats.restarts.to_str()} reductions=${st.stats.reductions.to_str()} collections=${st.stats.collections.to_str()} simplifications=${st.stats.simplifications.to_str()} simplified=${st.stats.simplified_clauses.to_str()}/${st.stats.simplified_literals.to_str()} deleted=${st.stats.deleted_clauses.to_str()} learnt_literals=${st.stats.learnt_literals_after.to_str()}/${st.stats.learnt_literals_before.to_str()} arena=${st.arena.len().to_str()}/${db.live_words.to_str()}"
    }

    solve_cnf : Dimacs.Cnf -> [Sat(Model.Assignment), Unsat]
    solve_cnf = |cnf| {
        (st, r, _) = solve(from_cnf(cnf, Bool.False), [])
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
    (seen, learnt, bt, touched, _, before, glue) = Analyze.analyze($arena, $trail, $trail_len, [0, 1, 2, 3, 0, 0, 0, 0], $level, $reason, st.seen, 4, $confl)
    $confl != Core.none and $confl != 1
    and (learnt.get(0) ?? 0) == lit(7, Bool.False)
    and (learnt.get(1) ?? 0) == lit(3, Bool.False)
    and learnt.len() == 3
    and bt == 3
    and touched.len() == 4
    and before == 3
    and glue == 3
    and seen.all(|s| s == 0)
}

expect [Solver.luby(2, 0), Solver.luby(2, 1), Solver.luby(2, 2), Solver.luby(2, 3), Solver.luby(2, 4), Solver.luby(2, 5), Solver.luby(2, 6), Solver.luby(2, 7)] == [1, 1, 2, 1, 1, 2, 4, 1]

expect Solver.solve_cnf({ num_vars: 0, clauses: [] }) == Sat([])
expect Solver.solve_cnf({ num_vars: 2, clauses: [] }) == Sat([2, 2])
expect Solver.solve_cnf({ num_vars: 0, clauses: [[]] }) == Unsat
expect Solver.solve_cnf({ num_vars: 2, clauses: [[0], [1]] }) == Unsat
expect Solver.solve_cnf({ num_vars: 2, clauses: [[0, 2], [0, 3], [1, 2], [1, 3]] }) == Unsat
expect Solver.solve_cnf({ num_vars: 3, clauses: [[0, 2], [1, 4], [3, 5]] }) == Sat([2, 1, 2])
expect Solver.solve_cnf({ num_vars: 3, clauses: [[0, 2, 4], [1, 2, 4], [0, 3, 4], [0, 2, 5], [1, 3, 4], [1, 2, 5], [0, 3, 5], [1, 3, 5]] }) == Unsat

# Root implications can reject an assumption without poisoning the next call.
expect {
    st0 = Solver.from_cnf({ num_vars: 1, clauses: [[0]] }, Bool.False)
    (st1, r1, final1) = Solver.solve(st0, [1])
    (st2, r2, final2) = Solver.solve(st1, [0])
    r1 == Unsat and final1 == [0] and st1.search.ok
    and r2 == Sat and final2.is_empty() and Solver.model(st2) == [Model.true_val]
}

# Contradictory assumptions and implication chains return clauses negating only assumptions.
expect {
    empty = Solver.new(1, Bool.False)
    (st1, r1, final1) = Solver.solve(empty, [0, 1])
    chain = Solver.from_cnf({ num_vars: 2, clauses: [[1, 2]] }, Bool.False)
    (st2, r2, final2) = Solver.solve(chain, [0, 3])
    r1 == Unsat and final1 == [0, 1] and st1.search.ok
    and r2 == Unsat and final2 == [2, 1] and st2.search.ok
}

# Already-true assumptions still occupy dummy levels, and another solve first restores level 0.
expect {
    st0 = Solver.from_cnf({ num_vars: 2, clauses: [[0]] }, Bool.False)
    (st1, r1, _) = Solver.solve(st0, [0, 0])
    (st2, r2, _) = Solver.solve(st1, [])
    r1 == Sat and st1.search.dl >= 2 and r2 == Sat and st2.search.ok
}

# Only a global root conflict permanently marks the state UNSAT and has no assumption conflict.
expect {
    st0 = Solver.from_cnf({ num_vars: 1, clauses: [[0], [1]] }, Bool.False)
    (st1, result, final) = Solver.solve(st0, [0])
    result == Unsat and final.is_empty() and !st1.search.ok
}

# Adding after SAT cancels decisions and propagates the new root clause.
expect {
    (sat, result, _) = Solver.solve(Solver.from_cnf({ num_vars: 2, clauses: [[0, 2]] }, Bool.False), [])
    added = Solver.add_clauses(sat, [[0]])
    result == Sat and added.search.dl == 0 and Solver.trail_of(added).contains(0)
}

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
