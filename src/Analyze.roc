# First-UIP conflict analysis (MiniSat `analyze`, no minimisation).

import Core

Analyze :: [].{
    # Precondition: decision level `dl` > 0 and `confl` is a clause with every literal false.
    # Returns `seen` (all zero again), the learnt clause with the asserting literal at index 0
    # and, when it has more than one literal, the literal of the highest remaining level at
    # index 1; and the backjump level.
    analyze : List(U32), List(U32), U64, List(U32), List(U32), List(U8), U32, U32 -> (List(U8), List(U32), U32)
    analyze = |arena, trail, trail_len, level, reason, seen, dl, confl| {
        var $seen = seen
        var $learnt = [0]
        var $to_clear = []
        var $path = 0
        var $p = 0
        var $first = Bool.True
        var $idx = trail_len - 1
        var $c = confl
        var $go = Bool.True
        while $go {
            expect $c != Core.none
            cu = $c.to_u64()
            end = cu + 2 + Core.clause_size(arena.get(cu) ?? 0)
            var $k = if $first { cu + 2 } else { cu + 3 }
            while $k < end {
                q = arena.get($k) ?? 0
                v = q.shr_wrap(1).to_u64()
                lv = level.get(v) ?? 0
                if ($seen.get(v) ?? 1) == 0 and lv > 0 {
                    $seen = Core.put($seen, v, 1)
                    $to_clear = $to_clear.append(v)
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
        for v in $to_clear {
            $seen = Core.put($seen, v, 0)
        }
        expect $seen.all(|s| s == 0)
        ($seen, $learnt, bt)
    }

    level_of : List(U32), List(U32), U64 -> U32
    level_of = |level, lits, i| level.get((lits.get(i) ?? 0).shr_wrap(1).to_u64()) ?? 0
}
