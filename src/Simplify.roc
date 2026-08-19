# Root-level clause simplification. New root units are traced by the caller before this module
# strengthens or deletes clauses, so every proof addition remains RUP against the preceding proof.

import Core
import Drat
import Model

Simplify :: [].{
    maybe : List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), U64, List(U8), Bool, Bool, U64 -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), U64, U64, U64, U64)
    maybe = |arena, pool, wofs, wlen, wcap, value, reason, trail, trail_len, bytes, proof_on, due, live_learnts| {
        if due {
            simplify(arena, value, reason, trail, trail_len, bytes, proof_on)
        } else {
            (arena, pool, wofs, wlen, wcap, reason, bytes, 0, 0, live_learnts, 0)
        }
    }

    # At a propagation fixed point on level 0, any unsatisfied non-unit clause has two unassigned
    # watches. Satisfied clauses can disappear; false trailing literals can be removed. Rebuilding
    # the arena also discards reduction tombstones and leaves no clause references to relocate after
    # all permanent root reasons have been cleared.
    simplify : List(U32), List(U8), List(U32), List(U32), U64, List(U8), Bool -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), U64, U64, U64, U64)
    simplify = |arena, value, reason, trail, trail_len, bytes, proof_on| {
        var $reason = reason
        var $i = 0
        while $i < trail_len {
            lit = trail.get($i) ?? 0
            expect (value.get(lit.to_u64()) ?? Model.unassigned) == Model.true_val
            $reason = Core.put($reason, lit.shr_wrap(1).to_u64(), Core.none)
            $i = $i + 1
        }

        var $fresh = [0]
        var $proof_delta = []
        var $removed = 0
        var $trimmed = 0
        var $live_learnts = 0
        var $c = 1
        while $c < arena.len() {
            header = arena.get($c) ?? 0
            size = Core.clause_size(header)
            if header.bitwise_and(Core.deleted_bit) == 0 {
                var $satisfied = Bool.False
                var $k = 0
                while $k < size and !$satisfied {
                    lit = arena.get($c + 2 + $k) ?? 0
                    if (value.get(lit.to_u64()) ?? Model.unassigned) == Model.true_val { $satisfied = Bool.True }
                    $k = $k + 1
                }
                if $satisfied {
                    if proof_on { $proof_delta = Drat.delete_clause($proof_delta, Core.clause_lits(arena, $c.to_u32_wrap())) }
                    $removed = $removed + 1
                } else {
                    expect (value.get((arena.get($c + 2) ?? 0).to_u64()) ?? Model.unassigned) == Model.unassigned
                    expect (value.get((arena.get($c + 3) ?? 0).to_u64()) ?? Model.unassigned) == Model.unassigned
                    var $lits = List.with_capacity(size)
                    $lits = $lits.append(arena.get($c + 2) ?? 0)
                    $lits = $lits.append(arena.get($c + 3) ?? 0)
                    $k = 2
                    while $k < size {
                        lit = arena.get($c + 2 + $k) ?? 0
                        if (value.get(lit.to_u64()) ?? Model.unassigned) != Model.false_val {
                            $lits = $lits.append(lit)
                        }
                        $k = $k + 1
                    }
                    if $lits.len() < size {
                        if proof_on {
                            $proof_delta = Drat.add_clause($proof_delta, $lits)
                            $proof_delta = Drat.delete_clause($proof_delta, Core.clause_lits(arena, $c.to_u32_wrap()))
                        }
                        $trimmed = $trimmed + size - $lits.len()
                    }
                    fresh_header = $lits.len().to_u32_wrap().bitwise_or(header.bitwise_and(Core.learnt_bit))
                    $fresh = $fresh.append(fresh_header).append(arena.get($c + 1) ?? 0).concat($lits)
                    if header.bitwise_and(Core.learnt_bit) != 0 { $live_learnts = $live_learnts + 1 }
                }
            }
            $c = $c + 2 + size
        }
        (pool, wofs, wlen, wcap) = Core.rebuild_watches($fresh, value.len())
        bytes1 = if proof_on { bytes.concat($proof_delta) } else { bytes }
        expect Core.watches_consistent($fresh, pool, wofs, wlen)
        ($fresh, pool, wofs, wlen, wcap, $reason, bytes1, $removed, $trimmed, $live_learnts, 1)
    }
}

expect {
    st = Core.new(4)
    (a1, p1, o1, l1, c1, sat) = Core.learn(st.arena, st.pool, st.wofs, st.wlen, st.wcap, [0, 4], Bool.False, 0)
    (arena, _, _, _, _, trim) = Core.learn(a1, p1, o1, l1, c1, [4, 6, 2], Bool.False, 0)
    (v1, lvs1, r1, t1, n1) = Core.assign(st.value, st.level, st.reason, st.trail, 0, 0, sat, 0)
    (value, _, reason, trail, trail_len) = Core.assign(v1, lvs1, r1, t1, n1, 3, trim, 0)
    (fresh, pool, wofs, wlen, _, cleared, proof, removed, trimmed, live, changed) = Simplify.simplify(arena, value, reason, trail, trail_len, [], Bool.True)
    removed == 1 and trimmed == 1 and live == 0 and changed == 1
    and fresh == [0, 2, 0, 4, 6]
    and cleared == List.repeat(Core.none, 4)
    and proof == "d 1 3 0\n3 4 0\nd 3 4 2 0\n".to_utf8()
    and Core.watches_consistent(fresh, pool, wofs, wlen)
}
