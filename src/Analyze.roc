# First-UIP conflict analysis with iterative recursive learned-clause minimisation.

import Core

Analyze :: [].{
    # Precondition: decision level `dl` > 0 and `confl` is a clause with every literal false.
    # Returns `seen` (all zero again), the minimized learnt clause with the asserting literal at
    # index 0 and, when it has more than one literal, the literal of the highest remaining level
    # at index 1; the backjump level; every derivation variable for the EVSIDS bump; and the clause
    # length before minimization.
    analyze : List(U32), List(U32), U64, List(U32), List(U32), List(U32), List(U8), U32, U32 -> (List(U8), List(U32), U32, List(U32), List(U32), U64, U32)
    analyze = |arena, trail, trail_len, trail_lim, level, reason, seen, dl, confl| {
        var $seen = seen
        var $learnt = [0]
        var $to_clear = []
        var $used_clauses = []
        var $path = 0
        var $p = 0
        var $first = Bool.True
        var $idx = trail_len - 1
        var $c = confl
        var $go = Bool.True
        while $go {
            expect $c != Core.none
            cu = $c.to_u64()
            if (arena.get(cu) ?? 0).bitwise_and(Core.learnt_bit) != 0 { $used_clauses = $used_clauses.append($c) }
            end = cu + 2 + Core.clause_size(arena.get(cu) ?? 0)
            var $k = if $first { cu + 2 } else { cu + 3 }
            while $k < end {
                q = arena.get($k) ?? 0
                v = q.shr_wrap(1).to_u64()
                lv = level.get(v) ?? 0
                if ($seen.get(v) ?? 1) == 0 and lv > 0 {
                    $seen = Core.put($seen, v, 1)
                    $to_clear = $to_clear.append(v.to_u32_wrap())
                    if lv == dl {
                        $path = $path + 1
                    } else {
                        $learnt = $learnt.append(q)
                    }
                }
                $k = $k + 1
            }
            while ($seen.get((trail.get($idx) ?? 0).shr_wrap(1).to_u64()) ?? 0) == 0 {
                $idx = $idx - 1
            }
            $p = trail.get($idx) ?? 0
            pv = $p.shr_wrap(1).to_u64()
            $seen = Core.put($seen, pv, 0)
            $c = reason.get(pv) ?? Core.none
            $path = $path - 1
            $first = Bool.False
            if $path == 0 {
                $go = Bool.False
            } else {
                $idx = $idx - 1
            }
        }
        $learnt = Core.put($learnt, 0, $p.bitwise_xor(1))
        before = $learnt.len()
        touched = $to_clear
        ($seen, $learnt, glue) = minimize(arena, trail, trail_lim, level, reason, $seen, $to_clear, $learnt)
        bt =
            if $learnt.len() == 1 {
                0
            } else {
                var $best = 1
                var $i = 2
                while $i < $learnt.len() {
                    if level_of(level, $learnt, $i) > level_of(level, $learnt, $best) { $best = $i }
                    $i = $i + 1
                }
                $learnt = $learnt.swap(1, $best) ?? $learnt
                level_of(level, $learnt, 1)
            }
        expect $seen.all(|s| s == 0)
        ($seen, $learnt, bt, touched, $used_clauses, before, glue)
    }

    # Derives the final conflict from a true literal that contradicts the next assumption. The
    # returned literals negate the participating assumptions; all temporary marks are cleared.
    final : List(U32), List(U32), U64, List(U32), List(U32), List(U32), List(U8), U32 -> (List(U8), List(U32))
    final = |arena, trail, trail_len, trail_lim, level, reason, seen, p| {
        var $seen = seen
        var $out = [p]
        pv = p.shr_wrap(1).to_u64()
        if (level.get(pv) ?? 0) > 0 {
            $seen = Core.put($seen, pv, 1)
            root = (trail_lim.get(0) ?? 0).to_u64()
            var $i = trail_len
            while $i > root {
                $i = $i - 1
                q = trail.get($i) ?? 0
                v = q.shr_wrap(1).to_u64()
                if ($seen.get(v) ?? 0) != 0 {
                    c = reason.get(v) ?? Core.none
                    if c == Core.none {
                        $out = $out.append(q.bitwise_xor(1))
                    } else {
                        cu = c.to_u64()
                        end = cu + 2 + Core.clause_size(arena.get(cu) ?? 0)
                        var $k = cu + 3
                        while $k < end {
                            r = arena.get($k) ?? 0
                            rv = r.shr_wrap(1).to_u64()
                            if (level.get(rv) ?? 0) > 0 {
                                $seen = Core.put($seen, rv, 1)
                            }
                            $k = $k + 1
                        }
                    }
                    $seen = Core.put($seen, v, 0)
                }
            }
        }
        $seen = Core.put($seen, pv, 0)
        expect $seen.all(|s| s == 0)
        ($seen, $out)
    }

    # MiniSat 2.2 recursive minimization. `source_clear` contains the derivation marks already in
    # `seen`; successful reason traversals remain marked so later candidates can reuse them. Before
    # clearing those marks, values 2 and 3 temporarily mark each learned decision level through its
    # decision variable, yielding exact LBD without another state list.
    minimize : List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32) -> (List(U8), List(U32), U32)
    minimize = |arena, trail, trail_lim, level, reason, seen, source_clear, learnt| {
        var $seen = seen
        var $min_clear = []
        var $levels = 0
        var $i = 1
        while $i < learnt.len() {
            lv = level_of(level, learnt, $i)
            $levels = $levels.bitwise_or(abstract_level(lv))
            $i = $i + 1
        }
        var $kept = [learnt.get(0) ?? 0]
        $i = 1
        while $i < learnt.len() {
            q = learnt.get($i) ?? 0
            r = reason.get(q.shr_wrap(1).to_u64()) ?? Core.none
            if r == Core.none {
                $kept = $kept.append(q)
            } else {
                (seen1, clear1, redundant) = lit_redundant(arena, level, reason, $seen, $min_clear, q, $levels)
                $seen = seen1
                $min_clear = clear1
                if !redundant { $kept = $kept.append(q) }
            }
            $i = $i + 1
        }
        var $glue = 0.U32
        $i = 0
        while $i < $kept.len() {
            lv = level_of(level, $kept, $i).to_u64()
            expect lv > 0
            decision = trail.get((trail_lim.get(lv - 1) ?? 0).to_u64()) ?? 0
            marker = decision.shr_wrap(1).to_u64()
            state = $seen.get(marker) ?? 0
            if state < 2 {
                $seen = Core.put($seen, marker, state + 2)
                $glue = $glue + 1
            }
            $i = $i + 1
        }
        for v in source_clear {
            $seen = Core.put($seen, v.to_u64(), 0)
        }
        for v in $min_clear {
            $seen = Core.put($seen, v.to_u64(), 0)
        }
        $i = 0
        while $i < $kept.len() {
            lv = level_of(level, $kept, $i).to_u64()
            decision = trail.get((trail_lim.get(lv - 1) ?? 0).to_u64()) ?? 0
            $seen = Core.put($seen, decision.shr_wrap(1).to_u64(), 0)
            $i = $i + 1
        }
        ($seen, $kept, $glue.min(255))
    }

    # A candidate is redundant when the transitive closure of its reason contains only source
    # variables, root assignments, or reasoned variables from levels represented in the clause.
    lit_redundant : List(U32), List(U32), List(U32), List(U8), List(U32), U32, U32 -> (List(U8), List(U32), Bool)
    lit_redundant = |arena, level, reason, seen, min_clear, candidate, abstract_levels| {
        var $seen = seen
        var $min_clear = min_clear
        top = min_clear.len()
        var $stack = [candidate]
        var $i = 0
        var $redundant = Bool.True
        while $i < $stack.len() and $redundant {
            p = $stack.get($i) ?? 0
            $i = $i + 1
            c = reason.get(p.shr_wrap(1).to_u64()) ?? Core.none
            expect c != Core.none
            cu = c.to_u64()
            end = cu + 2 + Core.clause_size(arena.get(cu) ?? 0)
            var $k = cu + 3
            while $k < end and $redundant {
                q = arena.get($k) ?? 0
                v = q.shr_wrap(1).to_u64()
                lv = level.get(v) ?? 0
                if ($seen.get(v) ?? 0) == 0 and lv > 0 {
                    r = reason.get(v) ?? Core.none
                    if r != Core.none and abstract_level(lv).bitwise_and(abstract_levels) != 0 {
                        $seen = Core.put($seen, v, 1)
                        $min_clear = $min_clear.append(v.to_u32_wrap())
                        $stack = $stack.append(q)
                    } else {
                        $redundant = Bool.False
                    }
                }
                $k = $k + 1
            }
        }
        if !$redundant {
            var $j = top
            while $j < $min_clear.len() {
                $seen = Core.put($seen, ($min_clear.get($j) ?? 0).to_u64(), 0)
                $j = $j + 1
            }
        }
        ($seen, $min_clear, $redundant)
    }

    abstract_level : U32 -> U32
    abstract_level = |lv| (1.U32).shl_wrap(lv.bitwise_and(31).to_u8_wrap())

    level_of : List(U32), List(U32), U64 -> U32
    level_of = |level, lits, i| level.get((lits.get(i) ?? 0).shr_wrap(1).to_u64()) ?? 0
}

# Recursive minimization removes a literal through a two-reason chain and clears every mark.
expect {
    st = Core.new(5)
    (a1, r2) = Core.alloc(st.arena, [4, 7], Bool.False, 0)
    (arena, r1) = Core.alloc(a1, [2, 5], Bool.False, 0)
    reason = [Core.none, r1, r2, Core.none, Core.none]
    seen = [0, 1, 0, 1, 1]
    (cleared, learnt, _) = Analyze.minimize(arena, [6, 8, 2, 0, 0], [0, 1, 2, 3, 0], [4, 3, 2, 1, 2], reason, seen, [1, 3, 4], [1, 3, 7, 9])
    learnt == [1, 7, 9] and cleared.all(|s| s == 0)
}

# A reason level absent from the learned clause blocks removal and still leaves no stale mark.
expect {
    st = Core.new(5)
    (a1, r2) = Core.alloc(st.arena, [4, 7], Bool.False, 0)
    (arena, r1) = Core.alloc(a1, [2, 5], Bool.False, 0)
    reason = [Core.none, r1, r2, Core.none, Core.none]
    seen = [0, 1, 0, 1, 1]
    (cleared, learnt, _) = Analyze.minimize(arena, [6, 8, 2, 0, 0], [0, 1, 2, 3, 0], [4, 3, 4, 1, 2], reason, seen, [1, 3, 4], [1, 3, 7, 9])
    learnt == [1, 3, 7, 9] and cleared.all(|s| s == 0)
}

# Final analysis resolves an implied contradiction back to both assumption decisions.
expect {
    st = Core.new(2)
    (arena, reason_clause) = Core.alloc(st.arena, [2, 1], Bool.False, 0)
    (v1, l1, r1, t1, n1) = Core.assign(st.value, st.level, st.reason, st.trail, 0, 0, Core.none, 1)
    (value, level, reason, trail, trail_len) = Core.assign(v1, l1, r1, t1, n1, 2, reason_clause, 1)
    (seen, final) = Analyze.final(arena, trail, trail_len, [0, 0], level, reason, st.seen, 2)
    value.len() == 4 and final == [2, 1] and seen.all(|s| s == 0)
}
