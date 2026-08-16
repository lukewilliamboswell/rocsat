app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Stderr
import pf.Path
import Dimacs

version = "0.0.0"

usage = Str.join_with(
    [
        "usage: rocsat <command> [args]",
        "",
        "commands:",
        "  parse <file.cnf>  read a DIMACS file and print its size",
        "  version           print the version",
        "  help              print this message",
    ],
    "\n",
)

main! : List(OsStr) => Try({}, _)
main! = |args| {
    cmd = args.drop_first(1).map(OsStr.display)
    match cmd {
        ["parse", file] => parse!(file)
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
