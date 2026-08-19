# Public incremental SAT API. Signed DIMACS literals are converted here; the engine keeps its
# compact internal literal encoding private to this boundary.

import Core
import Solver
import Branch
import Model
import Dimacs

Rocsat :: [].{
    State : { engine : Core.State, final : List(U32) }
    Error : [ZeroLiteral, LiteralOutOfRange(I32), UnknownVariable(I32), VariableLimit]
    Result : [Sat, Unsat]
    Value : [True, False, Unassigned]

    new : {} -> State
    new = |{}| { engine: Solver.new(0, Bool.False), final: [] }

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
    add_clause = |st, signed| {
        decoded = decode_all(signed)?
        engine = Solver.add_clauses(grow(st.engine, decoded.num_vars), [decoded.lits])
        Ok({ engine, final: [] })
    }

    solve : State, List(I32) -> Try((State, Result), Error)
    solve = |st, signed| {
        decoded = decode_all(signed)?
        (engine, result, final) = Solver.solve(grow(st.engine, decoded.num_vars), decoded.lits)
        Ok(({ engine, final }, result))
    }

    set_phase : State, I32 -> Try(State, Error)
    set_phase = |st, signed| {
        decoded = decode(signed)?
        engine0 = grow(st.engine, decoded.num_vars)
        phase = Core.put(engine0.phase, decoded.num_vars - 1, decoded.lit.bitwise_and(1).to_u8_wrap())
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
            activity = st.activity.concat(List.repeat(0, extra))
            heap0 = st.heap.concat(List.repeat(0, extra))
            hpos0 = st.hpos.concat(List.repeat(Branch.absent, extra))
            phase0 = st.phase.concat(List.repeat(1, extra))
            var $new_trail = List.with_capacity(extra)
            var $v = old
            while $v < requested {
                $new_trail = $new_trail.append((2 * $v + 1).to_u32_wrap())
                $v = $v + 1
            }
            (heap, hpos, phase, heap_len) = Branch.backtrack(activity, heap0, hpos0, st.search.heap_len, phase0, $new_trail, 0, extra)
            trail_lim = if st.trail_lim.len() < requested { st.trail_lim.concat(List.repeat(0, requested - st.trail_lim.len())) } else { st.trail_lim }
            {
                ..st,
                wofs: st.wofs.concat(List.repeat(0, lits_extra)),
                wlen: st.wlen.concat(List.repeat(0, lits_extra)),
                wcap: st.wcap.concat(List.repeat(0, lits_extra)),
                value: st.value.concat(List.repeat(Model.unassigned, lits_extra)),
                level: st.level.concat(List.repeat(0, extra)),
                reason: st.reason.concat(List.repeat(Core.none, extra)),
                trail: st.trail.concat(List.repeat(0, extra)),
                trail_lim,
                seen: st.seen.concat(List.repeat(0, extra)),
                activity,
                heap,
                hpos,
                phase,
                search: { ..st.search, heap_len },
            }
        }
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
