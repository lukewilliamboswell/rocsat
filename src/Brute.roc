# Brute-force reference solver: enumerates assignments variable by variable and abandons a
# prefix as soon as some clause has every literal false. No propagation, no watches, no learning —
# it exists to be an oracle the real solver is checked against, so it must stay this dumb.
# Capped at 24 variables.

import Dimacs
import Model

Brute :: [].{
    max_vars : U64
    max_vars = 24

    solve : Dimacs.Cnf -> Try([Sat(Model.Assignment), Unsat], [TooManyVars(U64)])
    solve = |cnf| {
        if cnf.num_vars > max_vars {
            return Err(TooManyVars(cnf.num_vars))
        }
        Ok(search(cnf.clauses, List.repeat(Model.unassigned, cnf.num_vars), 0))
    }

    search : List(List(U32)), Model.Assignment, U64 -> [Sat(Model.Assignment), Unsat]
    search = |clauses, assign, v| {
        if clauses.any(|c| c.all(|lit| lit_is_false(assign, lit))) {
            Unsat
        } else if v >= assign.len() {
            Sat(assign)
        } else {
            match search(clauses, assign.set(v, Model.true_val) ?? assign, v + 1) {
                Sat(a) => Sat(a)
                Unsat => search(clauses, assign.set(v, Model.false_val) ?? assign, v + 1)
            }
        }
    }

    lit_is_false : Model.Assignment, U32 -> Bool
    lit_is_false = |assign, lit| Model.lit_is_true(assign, lit.bitwise_xor(1))

    # Seeded random 3-CNF generator (Knuth's MMIX LCG), shared by the differential tests.
    random_cnf : U64, U64, U64 -> Dimacs.Cnf
    random_cnf = |seed, num_vars, num_clauses| {
        var $rng = seed
        var $clauses = []
        var $c = 0
        while $c < num_clauses {
            var $clause = []
            var $k = 0
            while $k < 3 {
                $rng = next_rng($rng)
                $clause = $clause.append(rng_below($rng, 2 * num_vars).to_u32_wrap())
                $k = $k + 1
            }
            $clauses = $clauses.append($clause)
            $c = $c + 1
        }
        { num_vars, clauses: $clauses }
    }

    next_rng : U64 -> U64
    next_rng = |x| x.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

    rng_below : U64, U64 -> U64
    rng_below = |x, n| x.shr_wrap(33) % n
}

expect Brute.solve({ num_vars: 0, clauses: [] }) == Ok(Sat([]))
expect Brute.solve({ num_vars: 0, clauses: [[]] }) == Ok(Unsat)
expect Brute.solve({ num_vars: 2, clauses: [[0], [1]] }) == Ok(Unsat)
expect Brute.solve({ num_vars: 3, clauses: [[0, 2], [1, 4], [3, 5]] }) == Ok(Sat([1, 2, 1]))
expect Brute.solve({ num_vars: 3, clauses: [[0, 2], [1, 4], [3, 5], [4, 5]] }) == Ok(Sat([1, 2, 1]))
expect Brute.solve({ num_vars: 2, clauses: [[0, 2], [0, 3], [1, 2], [1, 3]] }) == Ok(Unsat)
expect Brute.solve({ num_vars: 25, clauses: [] }) == Err(TooManyVars(25))
expect Brute.solve({ num_vars: 2, clauses: [[3, 1]] }) == Ok(Sat([1, 2]))

expect {
    var $seed = 1
    var $ok = Bool.True
    var $sat = 0
    while $seed <= 200 {
        cnf = Brute.random_cnf($seed, 8, 34)
        match Brute.solve(cnf) {
            Ok(Sat(a)) => {
                $sat = $sat + 1
                if Model.satisfies(a, cnf) != Ok({}) { $ok = Bool.False }
            }
            Ok(Unsat) => {}
            Err(_) => { $ok = Bool.False }
        }
        $seed = $seed + 1
    }
    $ok and $sat > 20 and $sat < 180
}
