# Learned-clause reduction and full watch rebuild. Deletions are traced only after no deleted
# clause can propagate through a stale watcher.

import Core
import Drat
import Model

Reduce :: [].{
    Counts : { original : U64, learnt : U64, live_words : U64, dead_words : U64 }

    counts : List(U32) -> Counts
    counts = |arena| {
        var $original = 0
        var $learnt = 0
        var $live_words = 1
        var $dead_words = 0
        var $c = 1
        while $c < arena.len() {
            header = arena.get($c) ?? 0
            words = 2 + Core.clause_size(header)
            if header.bitwise_and(Core.deleted_bit) != 0 {
                $dead_words = $dead_words + words
            } else {
                $live_words = $live_words + words
                if header.bitwise_and(Core.learnt_bit) == 0 { $original = $original + 1 } else { $learnt = $learnt + 1 }
            }
            $c = $c + words
        }
        { original: $original, learnt: $learnt, live_words: $live_words, dead_words: $dead_words }
    }

    # Ownership-preserving no-op boundary for the hot owner loop. Keeping the condition outside
    # this call makes the branch retain aliases of every list on this compiler.
    maybe : List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), List(U32), List(U8), Bool, Bool, U64 -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), U64, U64, U64)
    maybe = |arena, pool, wofs, wlen, wcap, value, reason, bytes, proof_on, due, live_learnts| {
        if due {
            reduce(arena, value, reason, bytes, proof_on)
        } else {
            (arena, pool, wofs, wlen, wcap, reason, bytes, 0, live_learnts, 0)
        }
    }

    # Ages all live learned clauses, removes half of the eligible clauses in worst-first order,
    # and returns a fresh watch pool. Binaries, assignment reasons, glue-2 core clauses, recently
    # used glue-3..6 clauses, and any used local clause survive.
    reduce : List(U32), List(U8), List(U32), List(U8), Bool -> (List(U32), List(U32), List(U32), List(U32), List(U32), List(U32), List(U8), U64, U64, U64)
    reduce = |arena, value, reason, bytes, proof_on| {
        var $arena = arena
        var $candidates = []
        var $live_learnts = 0
        var $c = 1
        while $c < $arena.len() {
            header = $arena.get($c) ?? 0
            size = Core.clause_size(header)
            if header.bitwise_and(Core.deleted_bit) == 0 and header.bitwise_and(Core.learnt_bit) != 0 {
                $live_learnts = $live_learnts + 1
                cref = $c.to_u32_wrap()
                meta = $arena.get($c + 1) ?? 0
                glue = Core.clause_glue(meta)
                used = Core.clause_used(meta)
                removable = if glue <= 2 { Bool.False } else if glue <= 6 { used < 2 } else { used == 0 }
                if size > 2 and !locked($arena, value, reason, cref) and removable {
                    $candidates = $candidates.append(cref)
                }
                $arena = Core.age_clause($arena, cref)
            }
            $c = $c + 2 + size
        }
        ranked = $candidates.sort_with(|a, b| worse_first($arena, a, b))
        target = if ranked.is_empty() { 0 } else { (ranked.len() / 2).max(1) }
        var $deletions = []
        var $i = 0
        while $i < target {
            cref = ranked.get($i) ?? Core.none
            if proof_on { $deletions = Drat.delete_clause($deletions, Core.clause_lits($arena, cref)) }
            $arena = Core.mark_deleted($arena, cref)
            $live_learnts = $live_learnts - 1
            $i = $i + 1
        }
        db = counts($arena)
        collect = db.dead_words * 5 > $arena.len()
        (arena1, reason1) = if collect { compact($arena, reason, value) } else { ($arena, reason) }
        (pool, wofs, wlen, wcap) = Core.rebuild_watches(arena1, value.len())
        bytes1 = if proof_on { bytes.concat($deletions) } else { bytes }
        expect Core.watches_consistent(arena1, pool, wofs, wlen)
        (arena1, pool, wofs, wlen, wcap, reason1, bytes1, target, $live_learnts, if collect { 1 } else { 0 })
    }

    # Copies live clauses and relocates every currently assigned non-unit reason. Stale reasons of
    # unassigned variables are intentionally left alone; assignment overwrites them before use.
    compact : List(U32), List(U32), List(U8) -> (List(U32), List(U32))
    compact = |arena, reason, value| {
        var $fresh = [0]
        var $reloc = List.repeat(Core.none, arena.len())
        var $c = 1
        while $c < arena.len() {
            header = arena.get($c) ?? 0
            words = 2 + Core.clause_size(header)
            if header.bitwise_and(Core.deleted_bit) == 0 {
                $reloc = Core.put($reloc, $c, $fresh.len().to_u32_wrap())
                var $k = 0
                while $k < words {
                    $fresh = $fresh.append(arena.get($c + $k) ?? 0)
                    $k = $k + 1
                }
            }
            $c = $c + words
        }
        var $reason = reason
        var $v = 0
        while $v < reason.len() {
            old = reason.get($v) ?? Core.none
            if old != Core.none and (value.get(2 * $v) ?? Model.unassigned) != Model.unassigned {
                moved = $reloc.get(old.to_u64()) ?? Core.none
                expect moved != Core.none
                $reason = Core.put($reason, $v, moved)
            }
            $v = $v + 1
        }
        ($fresh, $reason)
    }

    locked : List(U32), List(U8), List(U32), U32 -> Bool
    locked = |arena, value, reason, cref| {
        c = cref.to_u64()
        implied = arena.get(c + 2) ?? 0
        (value.get(implied.to_u64()) ?? Model.unassigned) == Model.true_val
        and (reason.get(implied.shr_wrap(1).to_u64()) ?? Core.none) == cref
    }

    worse_first : List(U32), U32, U32 -> [LT, EQ, GT]
    worse_first = |arena, a, b| {
        au = a.to_u64()
        bu = b.to_u64()
        ag = Core.clause_glue(arena.get(au + 1) ?? 0)
        bg = Core.clause_glue(arena.get(bu + 1) ?? 0)
        asize = Core.clause_size(arena.get(au) ?? 0)
        bsize = Core.clause_size(arena.get(bu) ?? 0)
        if ag != bg { bg.compare(ag) } else if asize != bsize { bsize.compare(asize) } else { a.compare(b) }
    }
}

expect {
    st = Core.new(6)
    (a1, p1, o1, l1, c1, core) = Core.learn(st.arena, st.pool, st.wofs, st.wlen, st.wcap, [0, 2, 4], Bool.True, 2)
    (a2, p2, o2, l2, c2, bad1) = Core.learn(a1, p1, o1, l1, c1, [1, 6, 8], Bool.True, 10)
    (a3, _, _, _, _, bad2) = Core.learn(a2, p2, o2, l2, c2, [3, 7, 10], Bool.True, 8)
    aged = Core.age_clause(Core.age_clause(a3, bad1), bad2)
    (arena, pool, wofs, wlen, _, _, _, deleted, live, collected) = Reduce.reduce(aged, st.value, st.reason, [], Bool.False)
    db = Reduce.counts(arena)
    deleted == 1 and live == 2 and collected == 1 and db.dead_words == 0 and db.learnt == 2
    and (arena.get(core.to_u64()) ?? 0).bitwise_and(Core.deleted_bit) == 0
    and Core.watches_consistent(arena, pool, wofs, wlen)
}
