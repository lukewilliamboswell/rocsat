# Text DRAT proof lines appended to a byte buffer: `l1 l2 ... 0` adds a clause, `d l1 ... 0`
# deletes one, a bare `0` is the empty clause. Literals are written as DIMACS integers.

Drat :: [].{
    add_clause : List(U8), List(U32) -> List(U8)
    add_clause = |proof, lits| lits.fold(proof, append_lit).append('0').append('\n')

    delete_clause : List(U8), List(U32) -> List(U8)
    delete_clause = |proof, lits| lits.fold(proof.append('d').append(' '), append_lit).append('0').append('\n')

    add_empty : List(U8) -> List(U8)
    add_empty = |proof| proof.append('0').append('\n')

    append_lit : List(U8), U32 -> List(U8)
    append_lit = |proof, lit| {
        signed = if lit.bitwise_and(1) == 1 { proof.append('-') } else { proof }
        signed.concat((lit.shr_wrap(1).to_u64() + 1).to_str().to_utf8()).append(' ')
    }
}

expect Drat.add_clause([], [0, 3, 4]) == "1 -2 3 0\n".to_utf8()
expect Drat.delete_clause([], [1]) == "d -1 0\n".to_utf8()
expect Drat.add_empty("x".to_utf8()) == "x0\n".to_utf8()
