# A separately compiled application that uses only rocsat's public signed-literal facade.

app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
    sat: "../src/main.roc",
}

import sat.Rocsat

main! = |args| {
    signed_one = if args.len() == 999999 { -1 } else { 1 }
    if assumptions_hold(signed_one) and preferences_hold(signed_one) and limit_holds(signed_one) {
        Ok({})
    } else {
        Err(ApiContractFailed)
    }
}

# Failed assumptions are reported and the state stays usable.
assumptions_hold : I32 -> Bool
assumptions_hold = |signed_one| {
    st0 = Rocsat.new({})
    st1 = Rocsat.add_clause(st0, [signed_one.negate(), 2]) ?? st0
    (st2, first) = Rocsat.solve(st1, [signed_one, -2]) ?? (st1, Sat)
    first_conflict = Rocsat.final_conflict(st2)
    first_failed = (Rocsat.failed(st2, signed_one) ?? Bool.False) and (Rocsat.failed(st2, -2) ?? Bool.False)
    (st3, second) = Rocsat.solve(st2, [signed_one.negate()]) ?? (st2, Unsat)
    first == Unsat and first_conflict == [2, signed_one.negate()] and first_failed
    and second == Sat and (Rocsat.value(st3, signed_one.negate()) ?? Unassigned) == True
}

# Exactly one of two variables is true. The preferred literals of a call choose which, earliest
# entry first, and the next call chooses again.
preferences_hold : I32 -> Bool
preferences_hold = |signed_one| {
    st0 = Rocsat.add_clauses_flat(Rocsat.new({}), [signed_one, 2, 0, signed_one.negate(), -2, 0]) ?? Rocsat.new({})
    (st1, first, spent) = Rocsat.solve_with(st0, { assumptions: [], preferred: [2, signed_one], max_conflicts: U64.highest }) ?? (st0, Unsat, nothing)
    st2 = Rocsat.add_clause(st1, [signed_one, 3]) ?? st1
    (st3, second, _) = Rocsat.solve_with(st2, { assumptions: [], preferred: [signed_one, 2], max_conflicts: U64.highest }) ?? (st2, Unsat, nothing)
    first == Sat and (Rocsat.value(st1, 2) ?? Unassigned) == True and (Rocsat.value(st1, signed_one) ?? Unassigned) == False
    and second == Sat and (Rocsat.value(st3, signed_one) ?? Unassigned) == True and (Rocsat.value(st3, 2) ?? Unassigned) == False
    and spent.decisions > 0 and spent.conflicts == 0
}

# All eight clauses over three variables have no model, and no search shows that without a
# conflict: a budget of zero gives up having spent nothing, a budget of one gives up at exactly one
# conflict, and the same state then finishes.
limit_holds : I32 -> Bool
limit_holds = |signed_one| {
    one = signed_one
    not_one = signed_one.negate()
    clauses = [[one, 2, 3], [one, 2, -3], [one, -2, 3], [one, -2, -3], [not_one, 2, 3], [not_one, 2, -3], [not_one, -2, 3], [not_one, -2, -3]]
    st0 = Rocsat.add_clauses(Rocsat.new({}), clauses) ?? Rocsat.new({})
    (st1, none, free) = Rocsat.solve_with(st0, { assumptions: [], preferred: [], max_conflicts: 0 }) ?? (st0, Sat, nothing)
    (st2, early, spent) = Rocsat.solve_with(st1, { assumptions: [], preferred: [], max_conflicts: 1 }) ?? (st1, Sat, nothing)
    (_, late, rest) = Rocsat.solve_with(st2, { assumptions: [], preferred: [], max_conflicts: 1000 }) ?? (st2, Sat, nothing)
    (_, plain) = Rocsat.solve(st2, []) ?? (st2, Sat)
    none == Unknown and free.conflicts == 0 and free.propagations == 0
    and early == Unknown and spent.conflicts == 1 and (Rocsat.value(st2, one) ?? True) == Unassigned
    and late == Unsat and plain == Unsat and rest.conflicts > 0
}

nothing : Rocsat.Counters
nothing = { conflicts: 0, decisions: 0, propagations: 0, restarts: 0, reductions: 0, collections: 0, simplifications: 0, simplified_clauses: 0, simplified_literals: 0, deleted_clauses: 0, learnt_literals_before: 0, learnt_literals_after: 0 }
