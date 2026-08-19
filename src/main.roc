app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Stderr
import pf.Path
import Dimacs
import Model
import Brute
import Rocsat
import Incremental

version = "0.0.0"

usage =
    \\usage: rocsat <command> [args]
    \\
    \\commands:
    \\  parse <file.cnf>  read a DIMACS file and print its size
    \\  solve <file.cnf> [proof.drat]  CDCL solve; exit 10 SAT / 20 UNSAT; DRAT proof if a path is given
    \\  incremental <file>  run `+ clause 0` / `? assumptions 0` operations
    \\  brute <file.cnf>  solve by enumeration (<= 24 vars); exit 10 SAT / 20 UNSAT
    \\  check <file.cnf> <model>  verify competition v-lines against the formula
    \\  version           print the version
    \\  help              print this message

main! : List(OsStr) => Try({}, _)
main! = |args| {
    cmd = args.drop_first(1).map(OsStr.display)
    match cmd {
        ["parse", file] => parse!(file)
        ["solve", file] => solve!(file, None)
        ["solve", file, proof] => solve!(file, Some(proof))
        ["incremental", file] => incremental!(file)
        ["brute", file] => brute!(file)
        ["check", file, model] => check!(file, model)
        ["version"] => Stdout.line!("rocsat ${version}")
        ["help"] => Stdout.line!(usage)
        _ => {
            Stderr.line!(usage)?
            Err(Exit(1))
        }
    }
}

read_cnf! : Str => Try(Dimacs.Cnf, _)
read_cnf! = |file| {
    bytes = Path.utf8(file).read_bytes!()?
    match Dimacs.parse(bytes) {
        Ok(cnf) => Ok(cnf)
        Err(e) => {
            Stderr.line!("c error: ${file}: ${describe_parse_error(e)}")?
            Err(Exit(1))
        }
    }
}

describe_parse_error : Dimacs.Error -> Str
describe_parse_error = |e| match e {
    MissingHeader(at) => "expected `p cnf V C` header at byte ${at.to_str()}"
    UnexpectedByte(at) => "unexpected byte at offset ${at.to_str()}"
    MissingTerminator => "last clause is missing its terminating 0"
    VariableTooLarge(at) => "variable at byte ${at.to_str()} exceeds ${Dimacs.max_var.to_str()}"
}

parse! : Str => Try({}, _)
parse! = |file| {
    cnf = read_cnf!(file)?
    lits = cnf.clauses.fold(0, |acc, c| acc + c.len())
    Stdout.line!("c vars=${cnf.num_vars.to_str()} clauses=${cnf.clauses.len().to_str()} lits=${lits.to_str()}")
}

solve! : Str, [Some(Str), None] => Try({}, _)
solve! = |file, proof_path| {
    cnf = read_cnf!(file)?
    st0 = Rocsat.from_cnf(cnf, proof_path != None)
    (st, result) = match Rocsat.solve(st0, []) {
        Ok(answer) => answer
        Err(err) => {
            Stderr.line!("c error: ${Str.inspect(err)}")?
            return Err(Exit(1))
        }
    }
    Stdout.line!(Rocsat.stats(st))?
    match proof_path {
        Some(path) => Path.utf8(path).write_bytes!(Rocsat.proof_bytes(st))?
        None => {}
    }
    match result {
        Sat => report_sat!(Rocsat.model(st))
        Unsat => report_unsat!({})
    }
}

incremental! : Str => Try({}, _)
incremental! = |file| {
    bytes = Path.utf8(file).read_bytes!()?
    operations = match Incremental.parse(bytes) {
        Ok(ops) => ops
        Err(err) => {
            Stderr.line!("c error: ${file}: ${Str.inspect(err)}")?
            return Err(Exit(1))
        }
    }
    var $state = Rocsat.new({})
    for operation in operations {
        match operation {
            Add(clause) => match Rocsat.add_clause($state, clause) {
                Ok(next) => { $state = next }
                Err(err) => {
                    Stderr.line!("c error: ${Str.inspect(err)}")?
                    return Err(Exit(1))
                }
            }
            Solve(assumptions) => match Rocsat.solve($state, assumptions) {
                Err(err) => {
                    Stderr.line!("c error: ${Str.inspect(err)}")?
                    return Err(Exit(1))
                }
                Ok((next, Sat)) => {
                    $state = next
                    Stdout.line!("s SATISFIABLE")?
                    for line in Model.format_v_lines(Rocsat.model($state)) { Stdout.line!(line)? }
                }
                Ok((next, Unsat)) => {
                    $state = next
                    Stdout.line!("s UNSATISFIABLE")?
                    Stdout.line!(format_final(Rocsat.final_conflict($state)))?
                }
            }
        }
    }
    Ok({})
}

format_final : List(I32) -> Str
format_final = |lits| {
    var $line = "u"
    for lit in lits { $line = $line.concat(" ${lit.to_str()}") }
    $line.concat(" 0")
}

report_sat! : Model.Assignment => Try({}, _)
report_sat! = |assign| {
    Stdout.line!("s SATISFIABLE")?
    for line in Model.format_v_lines(assign) {
        Stdout.line!(line)?
    }
    Err(Exit(10))
}

report_unsat! : {} => Try({}, _)
report_unsat! = |{}| {
    Stdout.line!("s UNSATISFIABLE")?
    Err(Exit(20))
}

brute! : Str => Try({}, _)
brute! = |file| {
    cnf = read_cnf!(file)?
    match Brute.solve(cnf) {
        Ok(Sat(assign)) => report_sat!(assign)
        Ok(Unsat) => report_unsat!({})
        Err(TooManyVars(n)) => {
            Stderr.line!("c error: ${n.to_str()} variables, brute force is capped at ${Brute.max_vars.to_str()}")?
            Err(Exit(1))
        }
    }
}

check! : Str, Str => Try({}, _)
check! = |file, model_file| {
    cnf = read_cnf!(file)?
    model_bytes = Path.utf8(model_file).read_bytes!()?
    assign = match Model.parse_v_lines(model_bytes, cnf.num_vars) {
        Ok(a) => a
        Err(e) => {
            Stderr.line!("c error: ${model_file}: ${Str.inspect(e)}")?
            return Err(Exit(1))
        }
    }
    match Model.satisfies(assign, cnf) {
        Ok({}) => Stdout.line!("c model ok")
        Err(Falsified(i)) => {
            Stderr.line!("c model falsifies clause ${i.to_str()}")?
            Err(Exit(1))
        }
    }
}
