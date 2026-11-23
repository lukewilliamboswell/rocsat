# EVSIDS variable ordering. The heap is a fixed-capacity max-heap with an explicit live length;
# assigned variables may remain until a pick discards them, and backtracking reinserts discarded
# variables. Equal activities prefer the lower variable id, keeping search deterministic.

import Core
import Model

Branch :: [].{
    absent : U32
    absent = 0xFFFFFFFF

    new : U64 -> (List(F64), List(U32), List(U32), U64)
    new = |n| {
        var $heap = List.with_capacity(n)
        var $hpos = List.with_capacity(n)
        var $v = 0
        while $v < n {
            $heap = $heap.append($v.to_u32_wrap())
            $hpos = $hpos.append($v.to_u32_wrap())
            $v = $v + 1
        }
        (List.repeat(0, n), $heap, $hpos, n)
    }

    # Bumps every variable visited by conflict analysis, repairs the heap upward, rescales when
    # needed, and applies the 0.95 decay by increasing the next bump amount.
    bump_all : List(F64), List(U32), List(U32), U64, List(U32), F64 -> (List(F64), List(U32), List(U32), F64)
    bump_all = |activity, heap, hpos, heap_len, touched, var_inc| {
        var $activity = activity
        var $heap = heap
        var $hpos = hpos
        var $rescale = Bool.False
        for v32 in touched {
            v = v32.to_u64()
            score = ($activity.get(v) ?? 0) + var_inc
            $activity = Core.put_f64($activity, v, score)
            if score > 1.0e100 { $rescale = Bool.True }
            var $i = ($hpos.get(v) ?? absent).to_u64()
            if $i != absent.to_u64() {
                while $i > 0 {
                    parent = ($i - 1) / 2
                    pv = ($heap.get(parent) ?? 0).to_u64()
                    pscore = $activity.get(pv) ?? 0
                    if score > pscore or (score == pscore and v < pv) {
                        $heap = Core.put($heap, $i, pv.to_u32_wrap())
                        $heap = Core.put($heap, parent, v32)
                        $hpos = Core.put($hpos, pv, $i.to_u32_wrap())
                        $hpos = Core.put($hpos, v, parent.to_u32_wrap())
                        $i = parent
                    } else {
                        $i = 0
                    }
                }
            }
        }
        next_inc = var_inc / 0.95
        if $rescale {
            var $v = 0
            while $v < $activity.len() {
                $activity = Core.put_f64($activity, $v, ($activity.get($v) ?? 0) * 1.0e-100)
                $v = $v + 1
            }
            # Scaling rounds, and underflows small scores to zero, so scores that differed can now
            # be equal while the heap still holds them in their old order.
            (ordered, positions) = reorder($activity, $heap, $hpos, heap_len)
            ($activity, ordered, positions, next_inc * 1.0e-100)
        } else {
            ($activity, $heap, $hpos, next_inc)
        }
    }

    # Restores the heap order of the live prefix bottom-up; an ordered heap is left as it is.
    reorder : List(F64), List(U32), List(U32), U64 -> (List(U32), List(U32))
    reorder = |activity, heap, hpos, heap_len| {
        var $heap = heap
        var $hpos = hpos
        var $start = heap_len / 2
        while $start > 0 {
            $start = $start - 1
            var $i = $start
            var $down = Bool.True
            while $down {
                left = 2 * $i + 1
                if left >= heap_len {
                    $down = Bool.False
                } else {
                    right = left + 1
                    lv = ($heap.get(left) ?? 0).to_u64()
                    best =
                        if right < heap_len {
                            rv = ($heap.get(right) ?? 0).to_u64()
                            ls = activity.get(lv) ?? 0
                            rs = activity.get(rv) ?? 0
                            if rs > ls or (rs == ls and rv < lv) { right } else { left }
                        } else {
                            left
                        }
                    bv = ($heap.get(best) ?? 0).to_u64()
                    mv = ($heap.get($i) ?? 0).to_u64()
                    bs = activity.get(bv) ?? 0
                    ms = activity.get(mv) ?? 0
                    if bs > ms or (bs == ms and bv < mv) {
                        $heap = Core.put($heap, $i, bv.to_u32_wrap())
                        $heap = Core.put($heap, best, mv.to_u32_wrap())
                        $hpos = Core.put($hpos, bv, $i.to_u32_wrap())
                        $hpos = Core.put($hpos, mv, best.to_u32_wrap())
                        $i = best
                    } else {
                        $down = Bool.False
                    }
                }
            }
        }
        ($heap, $hpos)
    }

    # Removes heap maxima until it finds an unassigned variable. The chosen variable is removed;
    # `num_vars` is returned when no variable remains.
    pick : List(F64), List(U32), List(U32), U64, List(U8), U64 -> (List(U32), List(U32), U64, U64)
    pick = |activity, heap, hpos, heap_len, value, num_vars| {
        var $heap = heap
        var $hpos = hpos
        var $len = heap_len
        var $picked = num_vars
        while $picked == num_vars and $len > 0 {
            root = ($heap.get(0) ?? 0).to_u64()
            $len = $len - 1
            $hpos = Core.put($hpos, root, absent)
            if $len > 0 {
                moved32 = $heap.get($len) ?? 0
                moved = moved32.to_u64()
                $heap = Core.put($heap, 0, moved32)
                $hpos = Core.put($hpos, moved, 0)
                var $i = 0
                var $down = Bool.True
                while $down {
                    left = 2 * $i + 1
                    if left >= $len {
                        $down = Bool.False
                    } else {
                        right = left + 1
                        lv = ($heap.get(left) ?? 0).to_u64()
                        best =
                            if right < $len {
                                rv = ($heap.get(right) ?? 0).to_u64()
                                ls = activity.get(lv) ?? 0
                                rs = activity.get(rv) ?? 0
                                if rs > ls or (rs == ls and rv < lv) { right } else { left }
                            } else {
                                left
                            }
                        bv = ($heap.get(best) ?? 0).to_u64()
                        bs = activity.get(bv) ?? 0
                        ms = activity.get(moved) ?? 0
                        if bs > ms or (bs == ms and bv < moved) {
                            $heap = Core.put($heap, $i, bv.to_u32_wrap())
                            $heap = Core.put($heap, best, moved32)
                            $hpos = Core.put($hpos, bv, $i.to_u32_wrap())
                            $hpos = Core.put($hpos, moved, best.to_u32_wrap())
                            $i = best
                        } else {
                            $down = Bool.False
                        }
                    }
                }
            }
            if (value.get(2 * root) ?? 0) == Model.unassigned { $picked = root }
        }
        ($heap, $hpos, $len, $picked)
    }

    # Saves the sign and reinserts previously discarded variables from an erased trail suffix.
    # `trail[start..end]` is unchanged storage whose assignments were just erased.
    backtrack : List(F64), List(U32), List(U32), U64, List(U8), List(U32), U64, U64 -> (List(U32), List(U32), List(U8), U64)
    backtrack = |activity, heap, hpos, heap_len, phase, trail, start, end| {
        var $heap = heap
        var $hpos = hpos
        var $phase = phase
        var $len = heap_len
        var $k = start
        while $k < end {
            lit = trail.get($k) ?? 0
            v32 = lit.shr_wrap(1)
            v = v32.to_u64()
            $phase = Core.put_u8($phase, v, lit.bitwise_and(1).to_u8_wrap())
            if ($hpos.get(v) ?? absent) == absent {
                expect $len < $heap.len()
                $heap = Core.put($heap, $len, v32)
                $hpos = Core.put($hpos, v, $len.to_u32_wrap())
                score = activity.get(v) ?? 0
                var $i = $len
                $len = $len + 1
                while $i > 0 {
                    parent = ($i - 1) / 2
                    pv = ($heap.get(parent) ?? 0).to_u64()
                    pscore = activity.get(pv) ?? 0
                    if score > pscore or (score == pscore and v < pv) {
                        $heap = Core.put($heap, $i, pv.to_u32_wrap())
                        $heap = Core.put($heap, parent, v32)
                        $hpos = Core.put($hpos, pv, $i.to_u32_wrap())
                        $hpos = Core.put($hpos, v, parent.to_u32_wrap())
                        $i = parent
                    } else {
                        $i = 0
                    }
                }
            }
            $k = $k + 1
        }
        ($heap, $hpos, $phase, $len)
    }

    # Heap and inverse-position invariant for the live prefix. O(n); tests only.
    consistent : List(F64), List(U32), List(U32), U64 -> Bool
    consistent = |activity, heap, hpos, heap_len| {
        var $ok = heap_len <= heap.len()
        var $i = 0
        while $i < heap_len {
            v = (heap.get($i) ?? absent).to_u64()
            if v >= hpos.len() or (hpos.get(v) ?? absent) != $i.to_u32_wrap() { $ok = Bool.False }
            if $i > 0 {
                parent = ($i - 1) / 2
                pv = (heap.get(parent) ?? absent).to_u64()
                vs = activity.get(v) ?? 0
                ps = activity.get(pv) ?? 0
                if vs > ps or (vs == ps and v < pv) { $ok = Bool.False }
            }
            $i = $i + 1
        }
        var $v = 0
        while $v < hpos.len() {
            pos = (hpos.get($v) ?? absent).to_u64()
            if pos != absent.to_u64() and (pos >= heap_len or (heap.get(pos) ?? absent).to_u64() != $v) { $ok = Bool.False }
            $v = $v + 1
        }
        $ok
    }
}

expect {
    (activity, heap, hpos, len) = Branch.new(5)
    (heap1, hpos1, len1, v0) = Branch.pick(activity, heap, hpos, len, List.repeat(Model.unassigned, 10), 5)
    (heap2, hpos2, phase2, len2) = Branch.backtrack(activity, heap1, hpos1, len1, List.repeat(1, 5), [0, 0, 0, 0, 0], 0, 1)
    v0 == 0 and len1 == 4 and len2 == 5 and (phase2.get(0) ?? 1) == 0 and Branch.consistent(activity, heap2, hpos2, len2)
}

expect {
    (activity, heap, hpos, len) = Branch.new(5)
    (activity1, heap1, hpos1, inc1) = Branch.bump_all(activity, heap, hpos, len, [3, 3, 1], 1.0)
    (heap2, hpos2, len2, v) = Branch.pick(activity1, heap1, hpos1, len, List.repeat(Model.unassigned, 10), 5)
    v == 3 and (activity1.get(3) ?? 0) == 2 and inc1 > 1 and Branch.consistent(activity1, heap2, hpos2, len2)
}

expect {
    (activity, heap, hpos, len) = Branch.new(3)
    assigned = [Model.true_val, Model.false_val, Model.unassigned, Model.unassigned, Model.unassigned, Model.unassigned]
    (heap1, hpos1, len1, v) = Branch.pick(activity, heap, hpos, len, assigned, 3)
    v == 1 and len1 == 1 and (hpos1.get(0) ?? 0) == Branch.absent and Branch.consistent(activity, heap1, hpos1, len1)
}

expect {
    (activity, heap, hpos, len) = Branch.new(2)
    (heap1, hpos1, len1, _) = Branch.pick(activity, heap, hpos, len, List.repeat(Model.unassigned, 4), 2)
    (heap2, hpos2, phase2, len2) = Branch.backtrack(activity, heap1, hpos1, len1, [1, 0], [0, 3], 0, 2)
    phase2 == [0, 1] and len2 == 2 and Branch.consistent(activity, heap2, hpos2, len2)
}

expect {
    (activity, heap, hpos, len) = Branch.new(1)
    (activity1, _, _, inc1) = Branch.bump_all(activity, heap, hpos, len, [0], 1.0e101)
    (activity1.get(0) ?? 0) < 100 and inc1 < 100
}

# A rescale that underflows keeps the heap ordered. Variable 2 (score 2e-300) is the heap parent of
# variable 1 (1e-300); bumping variable 3 past 1e100 scales both to zero, and equal scores must
# then come out lowest id first.
expect {
    (activity, heap, hpos, len) = Branch.new(4)
    (a1, h1, p1, _) = Branch.bump_all(activity, heap, hpos, len, [2], 2.0e-300)
    (a2, h2, p2, _) = Branch.bump_all(a1, h1, p1, len, [1], 1.0e-300)
    (a3, h3, p3, _) = Branch.bump_all(a2, h2, p2, len, [3], 1.0e101)
    unassigned = List.repeat(Model.unassigned, 8)
    (h4, p4, len4, first) = Branch.pick(a3, h3, p3, len, unassigned, 4)
    (h5, p5, len5, second) = Branch.pick(a3, h4, p4, len4, unassigned, 4)
    (h6, p6, len6, third) = Branch.pick(a3, h5, p5, len5, unassigned, 4)
    (_, _, _, fourth) = Branch.pick(a3, h6, p6, len6, unassigned, 4)
    h2 == [2, 1, 0, 3] and a3 == [0, 0, 0, 10] and Branch.consistent(a3, h3, p3, len)
    and [first, second, third, fourth] == [3, 0, 1, 2]
}

# Reordering only touches the live prefix and leaves an ordered heap alone.
expect {
    (activity, heap, hpos, len) = Branch.new(6)
    (a1, h1, p1, _) = Branch.bump_all(activity, heap, hpos, len, [4, 2, 4, 5], 1.0)
    (h2, p2) = Branch.reorder(a1, h1, p1, len)
    out = Branch.absent
    (h3, p3) = Branch.reorder([0, 0, 0, 0, 0, 0], [5, 4, 3, 2, 1, 0], [out, out, out, 2, 1, 0], 3)
    h2 == h1 and p2 == p1 and h3 == [3, 4, 5, 2, 1, 0] and p3 == [out, out, out, 0, 1, 2]
}
