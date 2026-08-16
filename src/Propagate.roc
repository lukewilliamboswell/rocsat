# Unit propagation with two watched literals and a blocking literal (MiniSat `propagate`).
# The hot loop of the solver: everything is inlined into one pair of `while` loops.

import Core
import Model

Propagate :: [].{
    # Propagates every literal on the trail from `qhead` on, at decision level `dl`. Returns the
    # updated lists, the trail length, `qhead`, the propagation count and the conflicting clause
    # or `Core.none`. On conflict the queue is still drained (`qhead = trail_len`).
    propagate : List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), U64, U64, U32, U64 -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U32), List(U32), U64, U64, U64, U32)
    propagate = |arena, pool, wofs, wlen, wcap, value, level, reason, trail, trail_len, qhead, dl, propagations| {
        var $arena = arena
        var $pool = pool
        var $wofs = wofs
        var $wlen = wlen
        var $wcap = wcap
        var $value = value
        var $level = level
        var $reason = reason
        var $trail = trail
        var $trail_len = trail_len
        var $qhead = qhead
        var $props = propagations
        var $confl = Core.none
        while $qhead < $trail_len {
            p = $trail.get($qhead) ?? 0
            $qhead = $qhead + 1
            $props = $props + 1
            false_lit = p.bitwise_xor(1)
            pu = p.to_u64()
            base = ($wofs.get(pu) ?? 0).to_u64()
            nw = ($wlen.get(pu) ?? 0).to_u64()
            var $i = 0
            var $j = 0
            while $i < nw {
                blocker = $pool.get(base + 2 * $i) ?? 0
                c = $pool.get(base + 2 * $i + 1) ?? 0
                $i = $i + 1
                if ($value.get(blocker.to_u64()) ?? 0) == Model.true_val {
                    $pool = Core.put($pool, base + 2 * $j, blocker)
                    $pool = Core.put($pool, base + 2 * $j + 1, c)
                    $j = $j + 1
                } else {
                    cu = c.to_u64()
                    l0 = $arena.get(cu + 2) ?? 0
                    l1 = $arena.get(cu + 3) ?? 0
                    first =
                        if l0 == false_lit {
                            $arena = Core.put($arena, cu + 2, l1)
                            $arena = Core.put($arena, cu + 3, false_lit)
                            l1
                        } else {
                            l0
                        }
                    if first != blocker and ($value.get(first.to_u64()) ?? 0) == Model.true_val {
                        $pool = Core.put($pool, base + 2 * $j, first)
                        $pool = Core.put($pool, base + 2 * $j + 1, c)
                        $j = $j + 1
                    } else {
                        end = cu + 2 + Core.clause_size($arena.get(cu) ?? 0)
                        var $k = cu + 4
                        while $k < end and ($value.get(($arena.get($k) ?? 0).to_u64()) ?? 0) == Model.false_val {
                            $k = $k + 1
                        }
                        if $k < end {
                            lk = $arena.get($k) ?? 0
                            $arena = Core.put($arena, cu + 3, lk)
                            $arena = Core.put($arena, $k, false_lit)
                            (pool1, wofs1, wlen1, wcap1) = Core.push_watch($pool, $wofs, $wlen, $wcap, lk.bitwise_xor(1), first, c)
                            $pool = pool1
                            $wofs = wofs1
                            $wlen = wlen1
                            $wcap = wcap1
                        } else {
                            $pool = Core.put($pool, base + 2 * $j, first)
                            $pool = Core.put($pool, base + 2 * $j + 1, c)
                            $j = $j + 1
                            if ($value.get(first.to_u64()) ?? 0) == Model.false_val {
                                $confl = c
                                $qhead = $trail_len
                                while $i < nw {
                                    $pool = Core.put($pool, base + 2 * $j, $pool.get(base + 2 * $i) ?? 0)
                                    $pool = Core.put($pool, base + 2 * $j + 1, $pool.get(base + 2 * $i + 1) ?? 0)
                                    $i = $i + 1
                                    $j = $j + 1
                                }
                            } else {
                                fu = first.to_u64()
                                $value = Core.put($value, fu, Model.true_val)
                                $value = Core.put($value, fu.bitwise_xor(1), Model.false_val)
                                $level = Core.put($level, fu.shr_wrap(1), dl)
                                $reason = Core.put($reason, fu.shr_wrap(1), c)
                                $trail = Core.put($trail, $trail_len, first)
                                $trail_len = $trail_len + 1
                            }
                        }
                    }
                }
            }
            $wlen = Core.put($wlen, pu, $j.to_u32_wrap())
        }
        expect $confl != Core.none or no_pending_clause($arena, $value)
        ($arena, $pool, $wofs, $wlen, $wcap, $value, $level, $reason, $trail, $trail_len, $qhead, $props, $confl)
    }

    # Invariant W after a conflict-free propagation: no live clause is unit or falsified.
    # O(arena); for `expect` bodies only.
    no_pending_clause : List(U32), List(U8) -> Bool
    no_pending_clause = |arena, value| {
        var $c = 1
        var $ok = Bool.True
        while $c < arena.len() {
            header = arena.get($c) ?? 0
            size = Core.clause_size(header)
            if header.bitwise_and(Core.deleted_bit) == 0 {
                var $k = 0
                var $sat = Bool.False
                var $unassigned = 0
                while $k < size {
                    v = value.get((arena.get($c + 2 + $k) ?? 0).to_u64()) ?? 0
                    if v == Model.true_val { $sat = Bool.True }
                    if v == Model.unassigned { $unassigned = $unassigned + 1 }
                    $k = $k + 1
                }
                if !$sat and $unassigned < 2 { $ok = Bool.False }
            }
            $c = $c + 2 + size
        }
        $ok
    }
}
