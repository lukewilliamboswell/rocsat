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

# Exactly one of two variables is true. The preferred literals choose which, earliest entry
# first, and the choice survives a clause added later.
preferences_hold : I32 -> Bool
preferences_hold = |signed_one| {
    st0 = Rocsat.add_clauses(Rocsat.new({}), [[signed_one, 2], [signed_one.negate(), -2]]) ?? Rocsat.new({})
    st1 = Rocsat.set_preferred(st0, [2, signed_one]) ?? st0
    (st2, first) = Rocsat.solve(st1, []) ?? (st1, Unsat)
    st3 = Rocsat.add_clause(st2, [signed_one, 3]) ?? st2
    (st4, second) = Rocsat.solve(st3, []) ?? (st3, Unsat)
    first == Sat and (Rocsat.value(st2, 2) ?? Unassigned) == True and (Rocsat.value(st2, signed_one) ?? Unassigned) == False
    and second == Sat and (Rocsat.value(st4, 2) ?? Unassigned) == True and (Rocsat.value(st4, 3) ?? Unassigned) == True
    and Rocsat.counters(st4).decisions > Rocsat.counters(st2).decisions
}

# All eight clauses over three variables have no model, and no search shows that without a
# conflict: a limit of zero gives up, and the same state then finishes without one.
limit_holds : I32 -> Bool
limit_holds = |signed_one| {
    one = signed_one
    not_one = signed_one.negate()
    clauses = [[one, 2, 3], [one, 2, -3], [one, -2, 3], [one, -2, -3], [not_one, 2, 3], [not_one, 2, -3], [not_one, -2, 3], [not_one, -2, -3]]
    st0 = Rocsat.add_clauses(Rocsat.new({}), clauses) ?? Rocsat.new({})
    (st1, early) = Rocsat.solve_limited(st0, [], 0) ?? (st0, Sat)
    (st2, late) = Rocsat.solve_limited(st1, [], 1000) ?? (st1, Sat)
    (_, plain) = Rocsat.solve(st1, []) ?? (st1, Sat)
    early == Unknown and Rocsat.counters(st1).conflicts == 0 and (Rocsat.value(st1, one) ?? True) == Unassigned
    and late == Unsat and plain == Unsat and Rocsat.counters(st2).conflicts > 0
}
