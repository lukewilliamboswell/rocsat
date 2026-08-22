# Text DRAT proof lines appended to a byte buffer: `l1 l2 ... 0` adds a clause, `d l1 ... 0`
# deletes one, and a bare `0` is the empty clause. Literals are written as DIMACS integers.
# Keep long-lived proof-buffer growth to one concatenation per line.

Drat :: [].{
    add_clause : List(U8), List(U32) -> List(U8)
    add_clause = |proof, lits| {
        line = lits.fold([], append_lit).append('0').append('\n')
        proof.concat(line)
    }

    delete_clause : List(U8), List(U32) -> List(U8)
    delete_clause = |proof, lits| {
        line = lits.fold("d ".to_utf8(), append_lit).append('0').append('\n')
        proof.concat(line)
    }

    add_empty : List(U8) -> List(U8)
    add_empty = |proof| proof.concat("0\n".to_utf8())

    append_lit : List(U8), U32 -> List(U8)
    append_lit = |proof, lit| {
        signed = if lit.bitwise_and(1) == 1 { proof.append('-') } else { proof }
        signed.concat((lit.shr_wrap(1).to_u64() + 1).to_str().to_utf8()).append(' ')
    }
}

expect Drat.add_clause([], [0, 3, 4]) == "1 -2 3 0\n".to_utf8()
expect Drat.delete_clause([], [1]) == "d -1 0\n".to_utf8()
expect Drat.add_empty("x".to_utf8()) == "x0\n".to_utf8()
