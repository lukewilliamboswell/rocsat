import fuzz.Fuzz
import Dimacs
import Rocsat

FuzzDimacs :: [].{
    suite = Fuzz.suite([roundtrip, malformed, header_budget])

    roundtrip = Fuzz.target_with({
        name: "dimacs-roundtrip",
        generator: Fuzz.list(Fuzz.list(Fuzz.u8_in(0, 31), 12), 40),
        test: |clauses| {
            if clauses.len() > 40 or clauses.any(|clause| clause.len() > 12) {
                return Fuzz.reject
            }
            encoded = clauses.map(|clause| clause.map(U8.to_u32))
            body = encoded.fold("", |text, clause| text.concat(render_clause(clause)))
            # Both header counts deliberately understate the generated input.
            vars = encoded.fold(0, |n, clause| clause.fold(n, |m, lit| m.max(lit.to_u64() // 2 + 1)))
            if Dimacs.parse("c generated\r\np cnf 0 0\r\n${body}%\n0\n".to_utf8()) != Ok({ num_vars: vars, clauses: encoded }) {
                crash "DIMACS parser changed literals or clause boundaries"
            }
            Fuzz.keep
        },
        show: Str.inspect,
        examples: [Fuzz.example({ name: "empty-duplicate-tautology", revision: "1", make: || [[], [0, 0, 1, 7]] })],
    })

    malformed = Fuzz.target_with({
        name: "dimacs-body-bytes",
        generator: Fuzz.raw_bytes,
        test: |body| {
            bytes = "p cnf 0 0\n".to_utf8().concat(body)
            match Dimacs.parse(bytes) {
                Ok(cnf) => {
                    if !cnf.clauses.all(|clause| clause.all(|lit| lit.to_u64() // 2 < cnf.num_vars)) {
                        crash "parsed literal is outside the reported variable range"
                    }
                }
                Err(MissingHeader(_)) => crash "valid DIMACS header was rejected"
                Err(UnexpectedByte(at)) | Err(VariableTooLarge(at)) => {
                    if at > bytes.len() {
                        crash "DIMACS diagnostic points past the end of the input"
                    }
                }
                Err(MissingTerminator) => {}
            }
            Fuzz.keep
        },
        show: Str.inspect,
        examples: [
            Fuzz.example({ name: "overflow", revision: "1", make: || "2147483648 0".to_utf8() }),
            Fuzz.example({ name: "truncated-sign", revision: "1", make: || "+".to_utf8() }),
        ],
    })

    header_budget = Fuzz.target_with!({
        name: "dimacs-header-allocation",
        generator: Fuzz.u64_in(0, 1000000),
        test!: |declared| {
            if declared > 1000000 { return Fuzz.reject }
            bytes = "p cnf 1 ${declared.to_str()}\n1 0\n".to_utf8()
            measured = Fuzz.measure!("parse", || Dimacs.parse(bytes))
            if measured.value != Ok({ num_vars: 1, clauses: [[0]] }) {
                crash "declared count changed the parsed clauses"
            }
            if measured.stats.requested_bytes > 1024 {
                crash "parsing one clause requested ${measured.stats.requested_bytes.to_str()} bytes"
            }
            Fuzz.keep
        },
        show: Str.inspect,
        examples: [Fuzz.example({ name: "million-declared-one-present", revision: "1", make: || 1000000 })],
    })

    render_clause : List(U32) -> Str
    render_clause = |clause| clause.fold("", |line, lit| line.concat("${Rocsat.to_signed(lit).to_str()} ")).concat("0\r\n")
}
