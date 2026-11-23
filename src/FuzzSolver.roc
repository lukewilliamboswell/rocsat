import fuzz.Fuzz
import Brute
import Dimacs
import Model
import Rocsat
import Solver

FuzzSolver :: [].{
    max_vars = 8.U64

    suite = Fuzz.suite([batch, incremental, limited, preferred, bulk, variable_growth])

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
            check_answer($state, result, { num_vars: max_vars, clauses: $clauses }, assumptions)
        }
        Fuzz.keep
    }

    # The state's answer under `assumptions` against brute force: a valid model, or failed
    # assumptions that really are jointly unsatisfiable.
    check_answer : Rocsat.State, [Sat, Unsat], Dimacs.Cnf, List(U32) -> {}
    check_answer = |state, result, cnf, assumptions| {
        restricted = with_assumptions(cnf, assumptions)
        match (result, Brute.solve(restricted)) {
            (Sat, Ok(Sat(_))) => {
                if Model.satisfies(Rocsat.model(state), restricted) != Ok({}) {
                    crash "incremental solver returned an invalid model"
                }
                if !Rocsat.final_conflict(state).is_empty() {
                    crash "SAT result retained a final conflict"
                }
            }
            (Unsat, Ok(Unsat)) => {
                signed = assumptions.map(Rocsat.to_signed)
                core = Rocsat.final_conflict(state).map(|lit| lit.negate())
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

    # One transcript turn of the limited and preferred targets: clauses to add, then a query whose
    # conflict limit and optional new preference list come from `knob`.
    turn = Fuzz.map2(
        Fuzz.map2(Fuzz.list(triple, 8), Fuzz.list(Fuzz.u8, 3), |clauses, assumptions| (clauses, assumptions)),
        Fuzz.map2(Fuzz.u8, Fuzz.list(Fuzz.u8, 8), |knob, prefer| (knob, prefer)),
        |(clauses, assumptions), (knob, prefer)| { clauses, assumptions, knob, prefer },
    )

    turn_fits = |item| item.clauses.len() <= 8 and item.assumptions.len() <= 3 and item.prefer.len() <= 8 and item.clauses.all(|clause| clause.len() <= 8)

    signed_all : List(List(U32)) -> List(List(I32))
    signed_all = |clauses| clauses.map(|clause| clause.map(Rocsat.to_signed))

    limited = Fuzz.target_with({
        name: "limited-vs-brute",
        generator: Fuzz.list(turn, 8),
        test: check_limited,
        show: Str.inspect,
        examples: [
            Fuzz.example({
                name: "zero-limit-then-resume",
                revision: "1",
                make: || [
                    { clauses: [[0, 2], [1, 3]], assumptions: [], knob: 0, prefer: [] },
                    { clauses: [[1], [2]], assumptions: [3], knob: 1, prefer: [] },
                ],
            }),
            Fuzz.example({
                name: "limit-above-need",
                revision: "1",
                make: || [{ clauses: [[0, 2, 4], [1, 3, 5], [0, 3, 4], [1, 2, 5]], assumptions: [4], knob: 7, prefer: [] }],
            }),
        ],
    })

    # Every query runs twice from the same state, without a limit and with one. A limit above the
    # conflicts the unlimited run met must reproduce that run exactly; otherwise the limited run
    # may only stop, or report a refutation the unlimited run also reports, and a stopped state must
    # hold nothing but implied values and still finish with the right answer.
    check_limited = |steps| {
        if steps.len() > 8 or !steps.all(turn_fits) {
            return Fuzz.reject
        }
        var $state = Rocsat.new({})
        var $clauses = []
        for item in steps {
            encoded = item.clauses.map(|clause| clause.map(|lit| encode(lit, max_vars)))
            $state = Rocsat.add_clauses($state, signed_all(encoded)) ?? crash "valid clauses were rejected"
            $clauses = $clauses.concat(encoded)
            cnf = { num_vars: max_vars, clauses: $clauses }
            assumptions = item.assumptions.map(|lit| encode(lit, max_vars))
            signed = assumptions.map(Rocsat.to_signed)
            limit = item.knob.to_u64() % 6
            before = Rocsat.counters($state).conflicts
            (full, answer) = Rocsat.solve($state, signed) ?? crash "valid assumptions were rejected"
            check_answer(full, answer, cnf, assumptions)
            needed = Rocsat.counters(full).conflicts - before
            (cut, outcome) = Rocsat.solve_limited($state, signed, limit) ?? crash "valid assumptions were rejected"
            spent = Rocsat.counters(cut).conflicts - before
            if limit > needed {
                if cut != full or outcome != (if answer == Sat { Sat } else { Unsat }) {
                    crash "a limit above the search's conflicts changed the search"
                }
                $state = cut
            } else {
                match outcome {
                    Sat => crash "a limit at or below the search's conflicts answered Sat"
                    Unsat => {
                        if answer != Unsat or spent > needed or !Rocsat.final_conflict(cut).is_empty() or Brute.solve(cnf) != Ok(Unsat) {
                            crash "a limited search refuted a formula that is not refuted"
                        }
                        $state = cut
                    }
                    Unknown => {
                        if spent < limit or spent > needed {
                            crash "a stopped search met ${spent.to_str()} conflicts under limit ${limit.to_str()} when ${needed.to_str()} answer"
                        }
                        if !Rocsat.final_conflict(cut).is_empty() {
                            crash "a stopped search retained a final conflict"
                        }
                        for lit in (0.U64).until(2 * max_vars) {
                            held = Rocsat.value(cut, Rocsat.to_signed(lit.to_u32_wrap())) == Ok(True)
                            if held and Brute.solve(with_assumptions(cnf, [lit.to_u32_wrap().bitwise_xor(1)])) != Ok(Unsat) {
                                crash "a stopped search reports a value the clauses do not imply"
                            }
                        }
                        (resumed, later) = Rocsat.solve(cut, signed) ?? crash "valid assumptions were rejected"
                        check_answer(resumed, later, cnf, assumptions)
                        $state = if item.knob >= 128 { resumed } else { cut }
                    }
                }
            }
        }
        Fuzz.keep
    }

    preferred = Fuzz.target_with({
        name: "preferred-vs-brute",
        generator: Fuzz.list(turn, 8),
        test: check_preferred,
        show: Str.inspect,
        examples: [
            Fuzz.example({
                name: "order-decides",
                revision: "1",
                make: || [
                    { clauses: [[0, 2], [1, 3]], assumptions: [], knob: 128, prefer: [0, 2] },
                    { clauses: [], assumptions: [], knob: 128, prefer: [2, 0] },
                    { clauses: [], assumptions: [3], knob: 0, prefer: [] },
                ],
            }),
            Fuzz.example({
                name: "forced-against-preference",
                revision: "1",
                make: || [{ clauses: [[1], [0, 2, 4]], assumptions: [5], knob: 129, prefer: [0, 4, 1, 2] }],
            }),
        ],
    })

    # Preferences persist until a step replaces them. Each query is first interrupted by a small
    # conflict limit and then finished, and every model, including one the interrupted call finds,
    # must be the lexicographically best model of the clauses and assumptions for the list in force.
    check_preferred = |steps| {
        if steps.len() > 8 or !steps.all(turn_fits) {
            return Fuzz.reject
        }
        var $state = Rocsat.new({})
        var $clauses = []
        var $prefer = []
        for item in steps {
            encoded = item.clauses.map(|clause| clause.map(|lit| encode(lit, max_vars)))
            $state = Rocsat.add_clauses($state, signed_all(encoded)) ?? crash "valid clauses were rejected"
            $clauses = $clauses.concat(encoded)
            if item.knob >= 128 {
                $prefer = item.prefer.map(|lit| encode(lit, max_vars))
                $state = Rocsat.set_preferred($state, $prefer.map(Rocsat.to_signed)) ?? crash "valid preferences were rejected"
            }
            cnf = { num_vars: max_vars, clauses: $clauses }
            assumptions = item.assumptions.map(|lit| encode(lit, max_vars))
            signed = assumptions.map(Rocsat.to_signed)
            restricted = with_assumptions(cnf, assumptions)
            (cut, outcome) = Rocsat.solve_limited($state, signed, item.knob.to_u64() % 4) ?? crash "valid assumptions were rejected"
            if outcome == Sat and (Model.satisfies(Rocsat.model(cut), restricted) != Ok({}) or !Brute.lex_best(restricted, $prefer, Rocsat.model(cut))) {
                crash "an interrupted search returned a model that is not the preferred one"
            }
            (next, result) = Rocsat.solve(cut, signed) ?? crash "valid assumptions were rejected"
            $state = next
            check_answer($state, result, cnf, assumptions)
            if result == Sat and !Brute.lex_best(restricted, $prefer, Rocsat.model($state)) {
                crash "the model is not the lexicographically best one for the preferred literals"
            }
        }
        Fuzz.keep
    }

    bulk = Fuzz.target_with({
        name: "bulk-add-vs-single",
        generator: Fuzz.list(
            Fuzz.map2(Fuzz.list(Fuzz.list(Fuzz.u8, 4), 8), Fuzz.u8, |clauses, knob| { clauses, knob }),
            6,
        ),
        test: check_bulk,
        show: Str.inspect,
        examples: [
            Fuzz.example({
                name: "units-empty-and-growth",
                revision: "1",
                make: || [
                    { clauses: [[0, 3], [2], [5, 5, 4]], knob: 1 },
                    { clauses: [[], [23]], knob: 0 },
                    { clauses: [[1], [7, 9]], knob: 1 },
                ],
            }),
            Fuzz.example({
                name: "empty-batch-keeps-model",
                revision: "1",
                make: || [{ clauses: [[12]], knob: 1 }, { clauses: [], knob: 0 }],
            }),
        ],
    })

    # From any reachable state, one bulk addition and the same clauses added one call at a time
    # must build equal states, variable growth and root propagation included.
    check_bulk = |batches| {
        if batches.len() > 6 or batches.any(|group| group.clauses.len() > 8 or group.clauses.any(|clause| clause.len() > 4)) {
            return Fuzz.reject
        }
        var $state = Rocsat.new({})
        for group in batches {
            clauses = signed_all(group.clauses.map(|clause| clause.map(|lit| encode(lit, 12))))
            together = Rocsat.add_clauses($state, clauses) ?? crash "valid clauses were rejected"
            var $single = $state
            for clause in clauses {
                $single = Rocsat.add_clause($single, clause) ?? crash "a valid clause was rejected"
            }
            if together != $single {
                crash "bulk addition and repeated single addition built different states"
            }
            $state =
                if group.knob % 2 == 1 {
                    (solved, _) = Rocsat.solve(together, []) ?? crash "an empty assumption list was rejected"
                    solved
                } else {
                    together
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
