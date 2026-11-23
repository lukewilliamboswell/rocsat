# DIMACS CNF reader.
#
# Lenient in the MiniSat sense: comment lines (`c`) and stray `p` lines are skipped wherever a
# token may start, clauses may span lines and end only at `0`, literals may carry a `+` prefix,
# the header's variable count is a lower bound (`num_vars = max(header, largest var seen)`), and
# the header's clause count is not checked. A `%` at token start ends the file (SATLIB files end
# with `%\n0`). A clause left open at end of file is an error, as is any other byte.
#
# Clauses come out exactly as written: duplicate literals and tautologies are kept. Normalisation
# belongs to the solver's clause adder, so that what the proof checker sees is what was read.
#
# Literal encoding: `2 * (var - 1) + (1 if negative)`, so `lit ^ 1` negates.

import Scanner

Dimacs :: [].{
    Cnf : { num_vars : U64, clauses : List(List(U32)) }

    Error : [
        MissingHeader(U64),
        UnexpectedByte(U64),
        MissingTerminator,
        VariableTooLarge(U64),
    ]

    max_var : U64
    max_var = Scanner.max_number

    read_number : List(U8), U64 -> Try({ value : U64, sign : U64, next : U64 }, Error)
    read_number = |bytes, start| match Scanner.read_number(bytes, start) {
        Ok(num) => Ok(num)
        Err(UnexpectedByte(at)) => Err(UnexpectedByte(at))
        Err(VariableTooLarge(at)) => Err(VariableTooLarge(at))
    }

    parse : List(U8) -> Try(Cnf, Error)
    parse = |bytes| {
        n = bytes.len()
        var $i = Scanner.skip_comments(bytes, 0)
        header = read_header(bytes, $i)?
        $i = header.next
        var $num_vars = header.num_vars
        # Even an empty clause needs a zero token and a separator. The header is
        # only a sizing hint, so an overstated count must not drive allocation.
        possible_clauses = (n - header.next + 1) // 2
        var $clauses = List.with_capacity(header.num_clauses.min(possible_clauses))
        var $lits = []
        var $done = Bool.False
        while !$done {
            $i = Scanner.skip_comments(bytes, $i)
            b = bytes.get($i) ?? 0
            if $i >= n or b == '%' {
                $done = Bool.True
            } else if b == 'p' {
                $i = Scanner.skip_line(bytes, $i)
            } else {
                num = read_number(bytes, $i)?
                $i = num.next
                if num.value == 0 {
                    $clauses = $clauses.append($lits)
                    $lits = []
                } else {
                    if num.value > $num_vars { $num_vars = num.value }
                    $lits = $lits.append((2 * (num.value - 1) + num.sign).to_u32_wrap())
                }
            }
        }
        if !$lits.is_empty() {
            Err(MissingTerminator)
        } else {
            Ok({ num_vars: $num_vars, clauses: $clauses })
        }
    }

    # `p cnf V C`, with any amount of whitespace between tokens.
    read_header : List(U8), U64 -> Try({ num_vars : U64, num_clauses : U64, next : U64 }, Error)
    read_header = |bytes, start| {
        if bytes.get(start) != Ok('p') {
            return Err(MissingHeader(start))
        }
        var $i = Scanner.skip_spaces(bytes, start + 1)
        if bytes.get($i) != Ok('c') or bytes.get($i + 1) != Ok('n') or bytes.get($i + 2) != Ok('f') {
            return Err(MissingHeader($i))
        }
        v = read_number(bytes, $i + 3)?
        c = read_number(bytes, v.next)?
        if v.sign != 0 or c.sign != 0 {
            return Err(MissingHeader(start))
        }
        Ok({ num_vars: v.value, num_clauses: c.value, next: c.next })
    }

}

expect Dimacs.parse("p cnf 2 1\n1 -2 0\n".to_utf8()) == Ok({ num_vars: 2, clauses: [[0, 3]] })
expect Dimacs.parse("c hi\nc there\np cnf 3 2\nc mid\n1 2 3 0\nc x\n-1 0\n".to_utf8()) == Ok({ num_vars: 3, clauses: [[0, 2, 4], [1]] })
expect Dimacs.parse("p cnf 3 1\n1\n2\n\n  3 0".to_utf8()) == Ok({ num_vars: 3, clauses: [[0, 2, 4]] })
expect Dimacs.parse("p cnf 3 1\n+3 -1 0\n".to_utf8()) == Ok({ num_vars: 3, clauses: [[4, 1]] })
expect Dimacs.parse("p cnf 1 1\n5 -7 0\n".to_utf8()) == Ok({ num_vars: 7, clauses: [[8, 13]] })
expect Dimacs.parse("p cnf 5 1\n1 0\n".to_utf8()) == Ok({ num_vars: 5, clauses: [[0]] })
expect Dimacs.parse("p cnf 2 2\n1 0\n0\n".to_utf8()) == Ok({ num_vars: 2, clauses: [[0], []] })
expect Dimacs.parse("p cnf 0 0\n".to_utf8()) == Ok({ num_vars: 0, clauses: [] })
expect Dimacs.parse("p cnf 0 0".to_utf8()) == Ok({ num_vars: 0, clauses: [] })
expect Dimacs.parse("p  cnf   2 1\r\n1 -2 0\r\n".to_utf8()) == Ok({ num_vars: 2, clauses: [[0, 3]] })
expect Dimacs.parse("p cnf 2 1\n1 -2 0\n%\n0\n".to_utf8()) == Ok({ num_vars: 2, clauses: [[0, 3]] })
expect Dimacs.parse("p cnf 2 1\n1 -2 0\np cnf 9 9\n2 0\n".to_utf8()) == Ok({ num_vars: 2, clauses: [[0, 3], [2]] })
expect Dimacs.parse("p cnf 2 1\n1 -2\n".to_utf8()) == Err(MissingTerminator)
expect Dimacs.parse("p cnf 2 1\n1 x 0\n".to_utf8()) == Err(UnexpectedByte(12))
expect Dimacs.parse("p cnf 2 1\n1 2c 0\n".to_utf8()) == Err(UnexpectedByte(13))
expect Dimacs.parse("1 2 0\n".to_utf8()) == Err(MissingHeader(0))
expect Dimacs.parse("c only comments\n".to_utf8()) == Err(MissingHeader(16))
expect Dimacs.parse("p cnf 1 1\n2147483648 0\n".to_utf8()) == Err(VariableTooLarge(10))
expect Dimacs.parse("p cnf 1 1\n2147483647 0\n".to_utf8()) == Ok({ num_vars: 2147483647, clauses: [[4294967292]] })
