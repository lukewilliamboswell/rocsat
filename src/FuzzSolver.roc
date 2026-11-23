import fuzz.Fuzz
import Brute
import Dimacs
import Model
import Rocsat
import Solver

FuzzSolver :: [].{
    max_vars = 8.U64

    suite = Fuzz.suite([batch, incremental, variable_growth])

    # Fixed-width clauses keep search inputs interesting. Independent lengths for
    # the clauses and assumption steps also exercise empty formulas and queries.
    triple = Fuzz.map2(
        Fuzz.u8,
        Fuzz.map2(Fuzz.u8, Fuzz.u8, |b, c| (b, c)),
        |a, (b, c)| [a, b, c],
    )

    batch = Fuzz.target_with({
        name: "cdcl-vs-brute",
        generator: Fuzz.map2(Fuzz.u64_in(1, max_vars), Fuzz.list(triple, 45), |vars, clauses| { vars, clauses }),
        test: check_batch,
        show: Str.inspect,
        examples: [
            Fuzz.example({ name: "empty-formula", revision: "1", make: || { vars: 1, clauses: [] } }),
            Fuzz.example({ name: "empty-clause", revision: "1", make: || { vars: 1, clauses: [[]] } }),
            Fuzz.example({ name: "four-binary-clauses", revision: "1", make: || { vars: 2, clauses: [[0, 2], [0, 3], [1, 2], [1, 3]] } }),
        ],
    })

    check_batch = |input| {
        if input.vars == 0 or input.vars > max_vars or input.clauses.len() > 45 or input.clauses.any(|clause| clause.len() > 8) {
            return Fuzz.reject
        }
        cnf = {
            num_vars: input.vars,
            clauses: input.clauses.map(|clause| clause.map(|lit| encode(lit, input.vars))),
        }
        match (Solver.solve_cnf(cnf), Brute.solve(cnf)) {
            (Sat(model), Ok(Sat(_))) if Model.satisfies(model, cnf) == Ok({}) => Fuzz.keep
            (Unsat, Ok(Unsat)) => Fuzz.keep
            (Sat(_), Ok(Sat(_))) => crash "CDCL returned an invalid model"
            _ => crash "CDCL and brute force disagree on satisfiability"
        }
    }

    incremental = Fuzz.target_with({
        name: "incremental-vs-brute",
        generator: Fuzz.list(
            Fuzz.map2(Fuzz.list(triple, 8), Fuzz.list(Fuzz.u8, 5), |clauses, assumptions| { clauses, assumptions }),
            10,
        ),
        test: check_transcript,
        show: Str.inspect,
        examples: [
            Fuzz.example({
                name: "failed-assumptions-and-reuse",
                revision: "1",
                make: || [
                    { clauses: [[1, 2]], assumptions: [0, 3] },
                    { clauses: [], assumptions: [1] },
                    { clauses: [[0], [3]], assumptions: [] },
                ],
            }),
            Fuzz.example({
                name: "opposite-assumptions",
                revision: "1",
                make: || [{ clauses: [], assumptions: [0, 0, 1] }, { clauses: [], assumptions: [] }],
            }),
        ],
    })

    check_transcript = |steps| {
        if steps.len() > 10 or steps.any(|step| step.clauses.len() > 8 or step.assumptions.len() > 5 or step.clauses.any(|clause| clause.len() > 8)) {
            return Fuzz.reject
        }
        var $state = Rocsat.new({})
        var $clauses = []
        for step in steps {
            for clause in step.clauses {
                encoded = clause.map(|lit| encode(lit, max_vars))
                $state = Rocsat.add_clause($state, encoded.map(Rocsat.to_signed)) ?? crash "valid incremental clause was rejected"
                $clauses = $clauses.append(encoded)
            }
            assumptions = step.assumptions.map(|lit| encode(lit, max_vars))
            signed = assumptions.map(Rocsat.to_signed)
            (next, result) = Rocsat.solve($state, signed) ?? crash "valid assumptions were rejected"
            $state = next
            cnf = { num_vars: max_vars, clauses: $clauses }
            restricted = with_assumptions(cnf, assumptions)
            match (result, Brute.solve(restricted)) {
                (Sat, Ok(Sat(_))) => {
                    if Model.satisfies(Rocsat.model($state), restricted) != Ok({}) {
                        crash "incremental solver returned an invalid model"
                    }
                    if !Rocsat.final_conflict($state).is_empty() {
                        crash "SAT result retained a final conflict"
                    }
                }
                (Unsat, Ok(Unsat)) => {
                    core = Rocsat.final_conflict($state).map(|lit| lit.negate())
                    if !core.all(|lit| signed.contains(lit)) {
                        crash "final conflict contains a literal outside the assumptions"
                    }
                    encoded_core = assumptions.keep_if(|lit| core.contains(Rocsat.to_signed(lit)))
                    if Brute.solve(with_assumptions(cnf, encoded_core)) != Ok(Unsat) {
                        crash "failed assumptions are satisfiable"
                    }
                }
                _ => crash "incremental solver and brute force disagree on satisfiability"
            }
        }
        Fuzz.keep
    }

    encode : U8, U64 -> U32
    encode = |lit, vars| (lit.to_u64() % (2 * vars)).to_u32_wrap()

    with_assumptions : Dimacs.Cnf, List(U32) -> Dimacs.Cnf
    with_assumptions = |cnf, assumptions| { ..cnf, clauses: cnf.clauses.concat(assumptions.map(|lit| [lit])) }

    variable_growth = Fuzz.target_with!({
        name: "incremental-variable-allocation",
        generator: Fuzz.u64_in(1, 1024),
        test!: |count| {
            if count == 0 or count > 1024 { return Fuzz.reject }
            measured = Fuzz.measure!("new-var", || {
                var $state = Rocsat.new({})
                for i in (0.U64).until(count) {
                    (next, id) = Rocsat.new_var($state) ?? crash "valid variable request failed"
                    if id.to_u64_wrap() != i + 1 { crash "new_var returned an unexpected ID" }
                    $state = next
                }
                Rocsat.num_vars($state)
            })
            if measured.value != count { crash "new_var changed the variable count incorrectly" }
            if measured.stats.allocs > 2 * count + 256 {
                crash "adding ${count.to_str()} variables made ${measured.stats.allocs.to_str()} allocation calls"
            }
            if measured.stats.requested_bytes > 512 * count + 4096 {
                crash "adding ${count.to_str()} variables requested ${measured.stats.requested_bytes.to_str()} bytes"
            }
            Fuzz.keep
        },
        show: Str.inspect,
        examples: [Fuzz.example({ name: "one-at-a-time", revision: "1", make: || 1024 })],
    })
}
