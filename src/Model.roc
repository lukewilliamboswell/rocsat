# Assignments and the model checker, independent of any solver internals.
#
# An `Assignment` holds one byte per variable: 0 unassigned, 1 true, 2 false. A clause is
# satisfied only by a literal assigned true; unassigned literals do not count, so partial
# assignments are accepted exactly when they already satisfy every clause.

import Dimacs

Model :: [].{
    Assignment : List(U8)

    unassigned : U8
    unassigned = 0
    true_val : U8
    true_val = 1
    false_val : U8
    false_val = 2

    lit_is_true : Assignment, U32 -> Bool
    lit_is_true = |assign, lit| {
        v = assign.get((lit.shr_wrap(1)).to_u64()) ?? unassigned
        if lit.bitwise_and(1) == 0 { v == true_val } else { v == false_val }
    }

    # `Err(Falsified(i))`: clause `i` has no true literal.
    satisfies : Assignment, Dimacs.Cnf -> Try({}, [Falsified(U64)])
    satisfies = |assign, cnf| {
        n = cnf.clauses.len()
        var $i = 0
        while $i < n {
            clause = cnf.clauses.get($i) ?? []
            if !clause.any(|lit| lit_is_true(assign, lit)) {
                return Err(Falsified($i))
            }
            $i = $i + 1
        }
        Ok({})
    }

    # Reads competition `v` lines (`v 1 -2 ... 0`, possibly several lines) into an assignment over
    # `num_vars` variables. Other lines are ignored. Literals past `num_vars` and contradictory
    # literals are errors.
    parse_v_lines : List(U8), U64 -> Try(Assignment, [VariableOutOfRange(U64), Contradiction(U64), UnexpectedByte(U64), MissingTerminator, NoValueLines])
    parse_v_lines = |bytes, num_vars| {
        n = bytes.len()
        var $assign = List.repeat(unassigned, num_vars)
        var $i = 0
        var $seen_v = Bool.False
        var $terminated = Bool.False
        while $i < n {
            b = bytes.get($i) ?? 0
            if b == 'v' and (bytes.get($i + 1) ?? ' ') == ' ' {
                $seen_v = Bool.True
                $i = $i + 1
                var $in_line = Bool.True
                while $in_line {
                    $i = skip_blanks(bytes, $i)
                    c = bytes.get($i) ?? '\n'
                    if c == '\n' or c == '\r' or $i >= n {
                        $in_line = Bool.False
                    } else {
                        num = match Dimacs.read_number(bytes, $i) {
                            Ok(x) => x
                            Err(_) => return Err(UnexpectedByte($i))
                        }
                        $i = num.next
                        if num.value == 0 {
                            $terminated = Bool.True
                        } else if num.value > num_vars {
                            return Err(VariableOutOfRange(num.value))
                        } else {
                            var_index = num.value - 1
                            want = if num.sign == 0 { true_val } else { false_val }
                            have = $assign.get(var_index) ?? unassigned
                            if have != unassigned and have != want {
                                return Err(Contradiction(num.value))
                            }
                            $assign = $assign.set(var_index, want) ?? $assign
                        }
                    }
                }
            } else {
                $i = Dimacs.skip_line(bytes, $i) + 1
            }
        }
        if !$seen_v {
            Err(NoValueLines)
        } else if !$terminated {
            Err(MissingTerminator)
        } else {
            Ok($assign)
        }
    }

    skip_blanks : List(U8), U64 -> U64
    skip_blanks = |bytes, start| {
        var $i = start
        while (bytes.get($i) ?? 0) == ' ' or (bytes.get($i) ?? 0) == '\t' {
            $i = $i + 1
        }
        $i
    }

    # Competition `v` lines for the assigned variables, each line at most 4096 bytes, ending in `0`.
    format_v_lines : Assignment -> List(Str)
    format_v_lines = |assign| {
        var $lines = []
        var $line = "v"
        var $v = 0
        n = assign.len()
        while $v < n {
            val = assign.get($v) ?? unassigned
            if val != unassigned {
                tok = if val == true_val { " ${($v + 1).to_str()}" } else { " -${($v + 1).to_str()}" }
                if $line.count_utf8_bytes() + tok.count_utf8_bytes() > 4094 {
                    $lines = $lines.append($line)
                    $line = "v"
                }
                $line = $line.concat(tok)
            }
            $v = $v + 1
        }
        $lines.append($line.concat(" 0"))
    }
}

cnf_3 : Dimacs.Cnf
cnf_3 = { num_vars: 3, clauses: [[0, 2], [1, 4], [3, 5]] }  # (1 ∨ 2)(¬1 ∨ 3)(¬2 ∨ ¬3)

expect Model.satisfies([1, 2, 1], cnf_3) == Ok({})
expect Model.satisfies([2, 1, 2], cnf_3) == Ok({})
expect Model.satisfies([1, 1, 1], cnf_3) == Err(Falsified(2))
expect Model.satisfies([2, 2, 2], cnf_3) == Err(Falsified(0))
expect Model.satisfies([1, 0, 1], cnf_3) == Err(Falsified(2))
expect Model.satisfies([1, 0, 0], cnf_3) == Err(Falsified(1))
expect Model.satisfies([], { num_vars: 0, clauses: [] }) == Ok({})
expect Model.satisfies([], { num_vars: 0, clauses: [[]] }) == Err(Falsified(0))

expect Model.parse_v_lines("s SATISFIABLE\nv 1 -2\nv 3 0\n".to_utf8(), 3) == Ok([1, 2, 1])
expect Model.parse_v_lines("v -1 0\n".to_utf8(), 3) == Ok([2, 0, 0])
expect Model.parse_v_lines("c note\nv 1 2 3\n".to_utf8(), 3) == Err(MissingTerminator)
expect Model.parse_v_lines("s SATISFIABLE\n".to_utf8(), 3) == Err(NoValueLines)
expect Model.parse_v_lines("v 1 -1 0\n".to_utf8(), 3) == Err(Contradiction(1))
expect Model.parse_v_lines("v 4 0\n".to_utf8(), 3) == Err(VariableOutOfRange(4))
expect Model.parse_v_lines("v 1 x 0\n".to_utf8(), 3) == Err(UnexpectedByte(4))
expect Model.parse_v_lines("v 0\n".to_utf8(), 3) == Ok([0, 0, 0])
expect Model.parse_v_lines("v 1 0".to_utf8(), 3) == Ok([1, 0, 0])

expect Model.format_v_lines([1, 2, 0, 1]) == ["v 1 -2 4 0"]
expect Model.format_v_lines([]) == ["v 0"]
expect {
    assign = List.repeat(2, 2000)
    lines = Model.format_v_lines(assign)
    lines.len() > 1 and lines.all(|l| l.count_utf8_bytes() <= 4096) and Model.parse_v_lines(Str.join_with(lines, "\n").to_utf8(), 2000) == Ok(assign)
}
