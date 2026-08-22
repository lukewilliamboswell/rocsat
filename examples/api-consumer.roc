# A separately compiled application that uses only rocsat's public signed-literal facade.

app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst" }

import Rocsat

main! = |args| {
    signed_one = if args.len() == 999999 { -1 } else { 1 }
    st0 = Rocsat.new({})
    st1 = Rocsat.add_clause(st0, [signed_one.negate(), 2]) ?? st0
    (st2, first) = Rocsat.solve(st1, [signed_one, -2]) ?? (st1, Sat)
    first_conflict = Rocsat.final_conflict(st2)
    first_failed = (Rocsat.failed(st2, signed_one) ?? Bool.False) and (Rocsat.failed(st2, -2) ?? Bool.False)
    (st3, second) = Rocsat.solve(st2, [signed_one.negate()]) ?? (st2, Unsat)
    if first == Unsat and first_conflict == [2, signed_one.negate()] and first_failed
        and second == Sat and (Rocsat.value(st3, signed_one.negate()) ?? Unassigned) == True {
        Ok({})
    } else {
        Err(ApiContractFailed)
    }
}
