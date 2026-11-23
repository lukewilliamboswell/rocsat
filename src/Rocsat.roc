# Public incremental SAT API. Signed DIMACS literals are converted here; the engine keeps its
# compact internal literal encoding private to this boundary.

import Core
import Solver
import Branch
import Model
import Dimacs
import Brute

Rocsat :: [].{
    State : { engine : Core.State, final : List(U32) }
    Error : [ZeroLiteral, LiteralOutOfRange(I32), UnknownVariable(I32), VariableLimit]
    Result : [Sat, Unsat]
    Outcome : [Sat, Unsat, Unknown]
    Value : [True, False, Unassigned]
    # What one `solve_with` call did: `conflicts`, `decisions`, `propagations` and `restarts`, and
    # the clause-database counts that the `stats` line totals.
    Counters : Core.Stats

    new : {} -> State
    new = |{}| { engine: Solver.new(0, Bool.False), final: [] }

    # A state that records a text DRAT proof for `proof_bytes`. The proof ends with the empty
    # clause only once the clauses are refuted without assumptions.
    new_with_proof : {} -> State
    new_with_proof = |{}| { engine: Solver.new(0, Bool.True), final: [] }

    from_cnf : Dimacs.Cnf, Bool -> State
    from_cnf = |cnf, proof_on| { engine: Solver.from_cnf(cnf, proof_on), final: [] }

    num_vars : State -> U64
    num_vars = |st| st.engine.level.len()

    new_var : State -> Try((State, I32), Error)
    new_var = |st| {
        old = num_vars(st)
        if old >= 2147483647 {
            Err(VariableLimit)
        } else {
            engine = grow(st.engine, old + 1)
            Ok(({ engine, final: [] }, (old + 1).to_u32_wrap().to_i32_wrap()))
        }
    }

    add_clause : State, List(I32) -> Try(State, Error)
    add_clause = |st, signed| add_clauses(st, [signed])

    # All of the clauses or, when any literal is invalid, none of them. Adding no clause is not a
    # mutation: the state, with any model or final conflict it holds, comes back as it was.
    add_clauses : State, List(List(I32)) -> Try(State, Error)
    add_clauses = |st, clauses| {
        if clauses.is_empty() {
            return Ok(st)
        }
        var $lits = List.with_capacity(clauses.fold(clauses.len(), |words, signed| words + signed.len()))
        var $num_vars = 0
        for signed in clauses {
            for item in signed {
                decoded = decode(item)?
                $lits = $lits.append(decoded.lit)
                $num_vars = $num_vars.max(decoded.num_vars)
            }
            $lits = $lits.append(Core.undef_lit)
        }
        engine = Solver.add_clauses(grow(st.engine, $num_vars), Flat($lits))
        Ok({ engine, final: [] })
    }

    # `add_clauses` for clauses that are held in one list: a `0` ends each clause, as in a DIMACS
    # file, so `[1, -2, 0, 2, 3, 0]` is `[[1, -2], [2, 3]]`. Literals after the last `0` are one
    # more clause, and a `0` with no literal before it is the empty clause. The only invalid
    # literal here is `I32.lowest`.
    add_clauses_flat : State, List(I32) -> Try(State, Error)
    add_clauses_flat = |st, signed| {
        if signed.is_empty() {
            return Ok(st)
        }
        var $lits = List.with_capacity(signed.len())
        var $num_vars = 0
        for item in signed {
            if item == 0 {
                $lits = $lits.append(Core.undef_lit)
            } else {
                decoded = decode(item)?
                $lits = $lits.append(decoded.lit)
                $num_vars = $num_vars.max(decoded.num_vars)
            }
        }
        engine = Solver.add_clauses(grow(st.engine, $num_vars), Flat($lits))
        Ok({ engine, final: [] })
    }

    # Spelled out instead of calling `solve_with`: carrying the state through one more
    # function made every call slower in proportion to the size of the formula.
    solve : State, List(I32) -> Try((State, Result), Error)
    solve = |st, signed| {
        decoded = decode_all(signed)?
        (engine, outcome, final, _) = Solver.solve(grow(st.engine, decoded.num_vars), decoded.lits, [], Solver.no_limit)
        Ok(({ engine, final }, Solver.answered(outcome)))
    }

    # `solve` with everything a single call can be given, and with what the call spent returned
    # beside its answer. Nothing given here outlives the call.
    #
    # `preferred` literals are branched on first, in list order, before any other variable, and no
    # saved phase overrides their signs. The model of a `Sat` answer is therefore the
    # lexicographically best one: each listed literal is true unless the clauses, the assumptions,
    # and the model's values of the literals listed before it together force it false. A variable
    # listed twice keeps its first entry. Variables not listed carry no promise.
    #
    # `max_conflicts` is a budget, and it is exact: the call stops at its `max_conflicts`-th
    # conflict and never meets another. It then answers `Unknown`, unless that conflict refuted
    # the clauses, which is `Unsat`. So `Unknown` always comes with `conflicts == max_conflicts`
    # in the counters, a search that needs fewer conflicts is the search `solve` runs, and a
    # budget of zero does no work. `U64.highest` is no budget. After `Unknown` the state is at the
    # root: learned clauses are kept, and `value` reports only literals the clauses imply.
    #
    # The counters say what this call did, whatever it answered.
    solve_with : State, { assumptions : List(I32), preferred : List(I32), max_conflicts : U64 } -> Try((State, Outcome, Counters), Error)
    solve_with = |st, query| {
        assumed = decode_all(query.assumptions)?
        preferred = decode_all(query.preferred)?
        # Two calls of the search on purpose. A client with a single call of `solve_with` otherwise
        # gets the whole search inlined into its own calling function, where the same loop was
        # measured about 3% slower.
        (engine, outcome, final, spent) =
            if preferred.lits.is_empty() {
                Solver.solve(grow(st.engine, assumed.num_vars), assumed.lits, [], query.max_conflicts)
            } else {
                Solver.solve(grow(st.engine, assumed.num_vars.max(preferred.num_vars)), assumed.lits, preferred.lits, query.max_conflicts)
            }
        Ok(({ engine, final }, outcome, spent))
    }

    set_phase : State, I32 -> Try(State, Error)
    set_phase = |st, signed| {
        decoded = decode(signed)?
        engine0 = grow(st.engine, decoded.num_vars)
        phase = Core.put_u8(engine0.phase, decoded.num_vars - 1, decoded.lit.bitwise_and(1).to_u8_wrap())
        Ok({ engine: { ..engine0, phase }, final: [] })
    }

    value : State, I32 -> Try(Value, Error)
    value = |st, signed| {
        decoded = decode(signed)?
        if decoded.num_vars > num_vars(st) {
            Err(UnknownVariable(signed))
        } else {
            current = st.engine.value.get(decoded.lit.to_u64()) ?? Model.unassigned
            if current == Model.true_val { Ok(True) } else if current == Model.false_val { Ok(False) } else { Ok(Unassigned) }
        }
    }

    model : State -> Model.Assignment
    model = |st| Solver.model(st.engine)

    failed : State, I32 -> Try(Bool, Error)
    failed = |st, signed| {
        decoded = decode(signed)?
        if decoded.num_vars > num_vars(st) {
            Err(UnknownVariable(signed))
        } else {
            Ok(st.final.contains(decoded.lit.bitwise_xor(1)))
        }
    }

    final_conflict : State -> List(I32)
    final_conflict = |st| st.final.map(to_signed)

    stats : State -> Str
    stats = |st| Solver.stats(st.engine)

    proof_bytes : State -> List(U8)
    proof_bytes = |st| st.engine.proof.bytes

    decode : I32 -> Try({ lit : U32, num_vars : U64 }, Error)
    decode = |signed| {
        if signed == 0 {
            Err(ZeroLiteral)
        } else if signed == I32.lowest {
            Err(LiteralOutOfRange(signed))
        } else {
            nvars = signed.abs().to_u64_wrap()
            sign = if signed < 0 { 1 } else { 0 }
            Ok({ lit: (2 * (nvars - 1) + sign).to_u32_wrap(), num_vars: nvars })
        }
    }

    decode_all : List(I32) -> Try({ lits : List(U32), num_vars : U64 }, Error)
    decode_all = |signed| {
        var $lits = List.with_capacity(signed.len())
        var $num_vars = 0
        for item in signed {
            decoded = decode(item)?
            $lits = $lits.append(decoded.lit)
            $num_vars = $num_vars.max(decoded.num_vars)
        }
        Ok({ lits: $lits, num_vars: $num_vars })
    }

    to_signed : U32 -> I32
    to_signed = |lit| {
        id = (lit.shr_wrap(1) + 1).to_i32_wrap()
        if lit.bitwise_and(1) == 0 { id } else { id.negate() }
    }

    # Variable growth is a cold API-boundary operation. New variables are inserted into the live
    # heap while root-assigned old variables remain absent.
    grow : Core.State, U64 -> Core.State
    grow = |input, requested| {
        st = Solver.to_root(input)
        old = st.level.len()
        if requested <= old {
            st
        } else {
            extra = requested - old
            lits_extra = 2 * extra
            activity = extend(st.activity, 0, extra)
            heap0 = extend(st.heap, 0, extra)
            hpos0 = extend(st.hpos, Branch.absent, extra)
            phase0 = extend(st.phase, 1, extra)
            var $new_trail = List.with_capacity(extra)
            var $v = old
            while $v < requested {
                $new_trail = $new_trail.append((2 * $v + 1).to_u32_wrap())
                $v = $v + 1
            }
            (heap, hpos, phase, heap_len) = Branch.backtrack(activity, heap0, hpos0, st.search.heap_len, phase0, $new_trail, 0, extra)
            trail_lim = if st.trail_lim.len() < requested { extend(st.trail_lim, 0, requested - st.trail_lim.len()) } else { st.trail_lim }
            {
                ..st,
                wofs: extend(st.wofs, 0, lits_extra),
                wlen: extend(st.wlen, 0, lits_extra),
                wcap: extend(st.wcap, 0, lits_extra),
                value: extend(st.value, Model.unassigned, lits_extra),
                level: extend(st.level, 0, extra),
                reason: extend(st.reason, Core.none, extra),
                trail: extend(st.trail, 0, extra),
                trail_lim,
                seen: extend(st.seen, 0, extra),
                activity,
                heap,
                hpos,
                phase,
                search: { ..st.search, heap_len },
            }
        }
    }

    # Single-variable growth can reuse append's spare capacity without a
    # temporary fill list. Larger jumps use the bulk fill.
    extend : List(a), a, U64 -> List(a)
    extend = |list, item, count| match count {
        1 => list.append(item)
        2 => list.append(item).append(item)
        _ => list.concat(List.repeat(item, count))
    }
}

expect Rocsat.decode_all([1, -2, 3]) == Ok({ lits: [0, 3, 4], num_vars: 3 })
expect Rocsat.decode(0) == Err(ZeroLiteral)
expect Rocsat.decode(I32.lowest) == Err(LiteralOutOfRange(I32.lowest))
expect Rocsat.to_signed(0) == 1 and Rocsat.to_signed(3) == -2

# Variables can be introduced explicitly or by literals, and phases remain caller-controlled.
expect {
    st0 = Rocsat.new({})
    (st1, v1) = Rocsat.new_var(st0) ?? (st0, 0)
    st2 = Rocsat.set_phase(st1, 1) ?? st1
    st3 = Rocsat.add_clause(st2, [-1, 3]) ?? st2
    (st4, result) = Rocsat.solve(st3, []) ?? (st3, Unsat)
    result == Sat and v1 == 1 and Rocsat.num_vars(st4) == 3
    and Rocsat.value(st4, -1) == Ok(False) and Rocsat.value(st4, 3) == Ok(True)
}

# Clause additions reuse one state and can monotonically change SAT to permanent UNSAT.
expect {
    st0 = Rocsat.new({})
    st1 = Rocsat.add_clause(st0, [1, 2]) ?? st0
    (st2, r1) = Rocsat.solve(st1, []) ?? (st1, Unsat)
    st3 = Rocsat.add_clause(st2, [-1]) ?? st2
    (st4, r2) = Rocsat.solve(st3, []) ?? (st3, Unsat)
    st5 = Rocsat.add_clause(st4, [-2]) ?? st4
    (st6, r3) = Rocsat.solve(st5, []) ?? (st5, Sat)
    r1 == Sat and r2 == Sat and r3 == Unsat and Rocsat.final_conflict(st6).is_empty()
}

# Failed assumptions are queryable, form a signed final conflict, and do not poison reuse.
expect {
    st0 = Rocsat.new({})
    st1 = Rocsat.add_clause(st0, [-1, 2]) ?? st0
    (st2, r1) = Rocsat.solve(st1, [1, -2]) ?? (st1, Sat)
    (st3, r2) = Rocsat.solve(st2, [-1]) ?? (st2, Unsat)
    r1 == Unsat and Rocsat.final_conflict(st2) == [2, -1]
    and Rocsat.failed(st2, 1) == Ok(Bool.True) and Rocsat.failed(st2, -2) == Ok(Bool.True)
    and r2 == Sat and Rocsat.final_conflict(st3).is_empty()
}

expect Rocsat.add_clause(Rocsat.new({}), [0]) == Err(ZeroLiteral)
expect Rocsat.value(Rocsat.new({}), 1) == Err(UnknownVariable(1))

# `holes + 1` pigeons, each in one of `holes` holes and no two together: unsatisfiable, and CDCL
# needs many conflicts to show it. Pigeon `p` sits in hole `h` when variable `p * holes + h + 1`
# is true.
pigeons : U64 -> List(List(I32))
pigeons = |holes| {
    seat = |p, h| (p * holes + h + 1).to_u32_wrap().to_i32_wrap()
    var $clauses = []
    var $p = 0
    while $p <= holes {
        var $somewhere = []
        var $h = 0
        while $h < holes {
            $somewhere = $somewhere.append(seat($p, $h))
            var $q = $p + 1
            while $q <= holes {
                $clauses = $clauses.append([seat($p, $h).negate(), seat($q, $h).negate()])
                $q = $q + 1
            }
            $h = $h + 1
        }
        $clauses = $clauses.append($somewhere)
        $p = $p + 1
    }
    $clauses
}

signed_clauses : Dimacs.Cnf -> List(List(I32))
signed_clauses = |cnf| cnf.clauses.map(|clause| clause.map(Rocsat.to_signed))

# `solve_with` on literals that are valid.
ask : Rocsat.State, List(I32), List(I32), U64 -> (Rocsat.State, Rocsat.Outcome, Rocsat.Counters)
ask = |st, assumptions, preferred, max_conflicts| Rocsat.solve_with(st, { assumptions, preferred, max_conflicts }) ?? crash "valid literals were rejected"

# With nothing preferred and no budget, `solve_with` is `solve`. A budget below what the search
# needs answers `Unknown` at exactly that many conflicts and leaves a root state that a later call
# finishes; a budget above it changes nothing.
expect {
    st0 = Rocsat.add_clauses(Rocsat.new({}), pigeons(4)) ?? Rocsat.new({})
    (full, answer) = Rocsat.solve(st0, []) ?? (st0, Sat)
    (whole, whole_answer, needed) = ask(st0, [], [], U64.highest)
    (cut, early, spent) = ask(st0, [], [], 3)
    (resumed, late, rest) = ask(cut, [], [], needed.conflicts)
    (same, same_answer, same_spent) = ask(st0, [], [], needed.conflicts + 1)
    answer == Unsat and whole_answer == Unsat and whole == full and needed.conflicts > 10
    and early == Unknown and spent.conflicts == 3 and spent.decisions > 0
    and Rocsat.final_conflict(cut).is_empty() and Rocsat.value(cut, 1) == Ok(Unassigned)
    and late == Unsat and rest.conflicts > 0 and rest.conflicts <= needed.conflicts and Rocsat.final_conflict(resumed).is_empty()
    and same_answer == Unsat and same == full and same_spent == needed
}

# Whatever the budget, the call never meets more conflicts than it was given, an answer is the
# answer of `solve`, `Unknown` comes at exactly the budget, and every value assigned after it is
# one the clauses imply.
expect {
    var $seed = 1
    var $ok = Bool.True
    var $unknown = 0
    while $seed <= 100 {
        cnf = Brute.random_cnf($seed, 8, 34)
        st0 = Rocsat.add_clauses(Rocsat.new({}), signed_clauses(cnf)) ?? Rocsat.new({})
        (_, answer) = Rocsat.solve(st0, []) ?? (st0, Sat)
        for limit in [0, 1, 2, 4] {
            (cut, outcome, spent) = ask(st0, [], [], limit)
            if spent.conflicts > limit { $ok = Bool.False }
            match outcome {
                Sat => if answer != Sat or Model.satisfies(Rocsat.model(cut), cnf) != Ok({}) { $ok = Bool.False }
                Unsat => if answer != Unsat { $ok = Bool.False }
                Unknown => {
                    $unknown = $unknown + 1
                    if spent.conflicts != limit { $ok = Bool.False }
                    var $lit = 0
                    while $lit < 16 {
                        forced = Rocsat.value(cut, Rocsat.to_signed($lit)) == Ok(True)
                        if forced and Brute.solve({ ..cnf, clauses: cnf.clauses.append([$lit.bitwise_xor(1)]) }) != Ok(Unsat) { $ok = Bool.False }
                        $lit = $lit + 1
                    }
                    (resumed, later) = Rocsat.solve(cut, []) ?? (cut, Sat)
                    if later != answer or (later == Sat and Model.satisfies(Rocsat.model(resumed), cnf) != Ok({})) { $ok = Bool.False }
                }
            }
        }
        $seed = $seed + 1
    }
    $ok and $unknown > 100
}

# Preferences pick among the models, earliest entry first. Clauses and assumptions still win, a
# variable's first entry is the one that counts, and each call goes by its own list alone.
expect {
    st0 = Rocsat.add_clauses(Rocsat.new({}), [[1, 2], [-1, -2]]) ?? Rocsat.new({})
    (a, ra, _) = ask(st0, [], [1, 2], U64.highest)
    (b, rb, _) = ask(a, [], [2, 1, -2], U64.highest)
    (c, rc, _) = ask(b, [-2], [2, 1, -2], U64.highest)
    (d, rd, _) = ask(c, [], [-1], U64.highest)
    st1 = Rocsat.add_clause(d, [-2]) ?? d
    (e, re, _) = ask(st1, [], [2, -1], U64.highest)
    ra == Sat and Rocsat.value(a, 1) == Ok(True) and Rocsat.value(a, 2) == Ok(False)
    and rb == Sat and Rocsat.value(b, 1) == Ok(False) and Rocsat.value(b, 2) == Ok(True)
    and rc == Sat and Rocsat.value(c, 1) == Ok(True) and Rocsat.value(c, 2) == Ok(False)
    and rd == Sat and Rocsat.value(d, 1) == Ok(False) and Rocsat.value(d, 2) == Ok(True)
    and re == Sat and Rocsat.value(e, 1) == Ok(True) and Rocsat.value(e, 2) == Ok(False)
}

# A preference may name a variable no clause has mentioned yet, and an invalid literal in either
# list is refused.
expect {
    st0 = Rocsat.new({})
    (st1, result, _) = ask(st0, [], [3], U64.highest)
    result == Sat and Rocsat.num_vars(st1) == 3 and Rocsat.value(st1, 3) == Ok(True) and Rocsat.value(st1, 1) == Ok(False)
    and Rocsat.solve_with(st0, { assumptions: [], preferred: [1, 0], max_conflicts: 1 }) == Err(ZeroLiteral)
    and Rocsat.solve_with(st0, { assumptions: [0], preferred: [1], max_conflicts: 1 }) == Err(ZeroLiteral)
}

# The same list given to every call survives whatever the state went through in between,
# backtracking, added clauses and calls that ran out: enumerating with blocking clauses yields,
# each time, the lexicographically best model that is left.
expect {
    var $seed = 1
    var $ok = Bool.True
    var $models = 0
    while $seed <= 100 {
        cnf = Brute.random_cnf($seed, 8, 16 + 6 * ($seed % 4))
        var $rng = Brute.next_rng($seed)
        var $prefer = []
        while $prefer.len() < 2 + $seed % 7 {
            $rng = Brute.next_rng($rng)
            $prefer = $prefer.append(Brute.rng_below($rng, 16).to_u32_wrap())
        }
        preferred = $prefer.map(Rocsat.to_signed)
        var $state = Rocsat.add_clauses(Rocsat.new({}), signed_clauses(cnf)) ?? Rocsat.new({})
        var $clauses = cnf.clauses
        var $round = 0
        while $round < 5 {
            current = { num_vars: 8, clauses: $clauses }
            (cut, _, _) = ask($state, [], preferred, $round)
            (next, result, _) = ask(cut, [], preferred, U64.highest)
            $state = next
            match (result, Brute.solve(current)) {
                (Sat, Ok(Sat(_))) => {
                    $models = $models + 1
                    model = Rocsat.model($state)
                    if Model.satisfies(model, current) != Ok({}) or !Brute.lex_best(current, $prefer, model) { $ok = Bool.False }
                    var $block = []
                    var $v = 0
                    while $v < 8 {
                        $block = $block.append(if Model.lit_is_true(model, 2 * $v) { 2 * $v + 1 } else { 2 * $v })
                        $v = $v + 1
                    }
                    $clauses = $clauses.append($block)
                    $state = Rocsat.add_clause($state, $block.map(Rocsat.to_signed)) ?? $state
                }
                (Unsat, Ok(Unsat)) => {}
                _ => { $ok = Bool.False }
            }
            $round = $round + 1
        }
        $seed = $seed + 1
    }
    $ok and $models > 200
}

# One bulk addition, nested or flat, builds exactly the state that the same clauses build one
# call at a time, units, duplicates, tautologies and root conflicts included. The flat form may
# leave its last clause open.
expect {
    var $seed = 1
    var $ok = Bool.True
    while $seed <= 100 {
        cnf = Brute.random_cnf($seed, 12, 4 * ($seed % 12))
        clauses = signed_clauses(cnf).map_with_index(|clause, i| clause.take_first(1 + (i + $seed) % 3))
        bulk = Rocsat.add_clauses(Rocsat.new({}), clauses)
        var $single = Ok(Rocsat.new({}))
        var $flat = []
        for clause in clauses {
            $single = match $single {
                Ok(st) => Rocsat.add_clause(st, clause)
                Err(err) => Err(err)
            }
            $flat = $flat.concat(clause).append(0)
        }
        if bulk != $single or bulk == Err(ZeroLiteral) { $ok = Bool.False }
        if Rocsat.add_clauses_flat(Rocsat.new({}), $flat) != bulk or Rocsat.add_clauses_flat(Rocsat.new({}), $flat.drop_last(1)) != bulk { $ok = Bool.False }
        $seed = $seed + 1
    }
    $ok
}

# Adding no clause leaves a model and a final conflict in place, as adding none one at a time does.
expect {
    st0 = Rocsat.add_clauses(Rocsat.new({}), [[1, 2]]) ?? Rocsat.new({})
    (sat, _) = Rocsat.solve(st0, []) ?? (st0, Unsat)
    (unsat, _) = Rocsat.solve(st0, [-1, -2]) ?? (st0, Sat)
    Rocsat.add_clauses(sat, []) == Ok(sat) and Rocsat.add_clauses_flat(sat, []) == Ok(sat) and Rocsat.value(sat, 2) == Ok(True)
    and Rocsat.add_clauses(unsat, []) == Ok(unsat) and Rocsat.add_clauses_flat(unsat, []) == Ok(unsat) and !Rocsat.final_conflict(unsat).is_empty()
}

expect Rocsat.add_clauses(Rocsat.new({}), [[1], [2, 0]]) == Err(ZeroLiteral)
expect Rocsat.add_clauses(Rocsat.new({}), [[]]).map_ok(|st| Rocsat.solve(st, [])) == Rocsat.add_clause(Rocsat.new({}), []).map_ok(|st| Rocsat.solve(st, []))

# In the flat form a zero ends a clause, a zero right after another is the empty clause, and one
# literal out of range refuses the whole list.
expect Rocsat.add_clauses_flat(Rocsat.new({}), [1, -2, 0, 2, 3, 0]) == Rocsat.add_clauses(Rocsat.new({}), [[1, -2], [2, 3]])
expect Rocsat.add_clauses_flat(Rocsat.new({}), [1, 0, 0, 4]) == Rocsat.add_clauses(Rocsat.new({}), [[1], [], [4]])
expect Rocsat.add_clauses_flat(Rocsat.new({}), [0]) == Rocsat.add_clause(Rocsat.new({}), [])
expect Rocsat.add_clauses_flat(Rocsat.new({}), [1, 0, I32.lowest, 0]) == Err(LiteralOutOfRange(I32.lowest))

# The counters of a call are what it added to the totals of the `stats` line, and a call that
# finds its state already refuted spends nothing.
expect {
    st0 = Rocsat.add_clauses(Rocsat.new({}), pigeons(3)) ?? Rocsat.new({})
    (st1, result, first) = ask(st0, [], [], U64.highest)
    (st2, again, second) = ask(st1, [1], [], U64.highest)
    result == Unsat and first.conflicts > 0 and first.decisions > 0 and first.propagations > 0
    and Rocsat.stats(st1).starts_with("c conflicts=${first.conflicts.to_str()} decisions=${first.decisions.to_str()} propagations=${first.propagations.to_str()} restarts=${first.restarts.to_str()} ")
    and again == Unsat and second.conflicts == 0 and second.decisions == 0 and second.propagations == 0
    and Rocsat.stats(st2) == Rocsat.stats(st1)
}

# A proof is recorded only when asked for, across clause batches and a call that ran out, and it
# closes with the empty clause when the clauses are refuted.
expect {
    half = Rocsat.add_clauses(Rocsat.new_with_proof({}), [[1, 2], [-1, 2]]) ?? Rocsat.new({})
    (cut, early, _) = ask(half, [-2], [], 0)
    whole = Rocsat.add_clauses_flat(cut, [1, -2, 0, -1, -2, 0]) ?? cut
    (refuted, answer) = Rocsat.solve(whole, []) ?? (whole, Sat)
    plain = Rocsat.add_clauses(Rocsat.new({}), [[1, 2], [-1, 2], [1, -2], [-1, -2]]) ?? Rocsat.new({})
    (silent, _) = Rocsat.solve(plain, []) ?? (plain, Sat)
    proof = Rocsat.proof_bytes(refuted)
    early == Unknown and answer == Unsat and Rocsat.proof_bytes(cut).is_empty()
    and proof.take_last(3) == "\n0\n".to_utf8() and Rocsat.proof_bytes(silent).is_empty()
}
