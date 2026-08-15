# Nominal record type with methods — the shape a real `Solver` type would take.

Sol := { blocks : List(U64), counts : List(U64) }.{
    new : U64, U64 -> Sol
    new = |m, cap| Sol.{ blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }

    step : Sol, U64, U64, U64 -> Sol
    step = |Sol.{ blocks, counts }, lit, cap, i| {
        c = counts.get(lit) ?? 0
        b = blocks.set((lit * cap) + c, i) ?? blocks
        cs = counts.set(lit, c + 1) ?? counts
        Sol.{ blocks: b, counts: cs }
    }

    count_of : Sol, U64 -> U64
    count_of = |Sol.{ counts, .. }, lit| counts.get(lit) ?? 0

    write : Sol, U64, U64, U64, U64 -> Sol
    write = |Sol.{ blocks, counts }, lit, cap, c, i| {
        b = blocks.set((lit * cap) + c, i) ?? blocks
        cs = counts.set(lit, c + 1) ?? counts
        Sol.{ blocks: b, counts: cs }
    }

    run : Sol, U64, U64, U64, U64 -> Sol
    run = |st, i, n, m, cap| {
        if i >= n {
            st
        } else {
            run(step(st, i % m, cap, i), i + 1, n, m, cap)
        }
    }

    checksum : Sol -> U64
    checksum = |Sol.{ blocks, counts }|
        counts.fold(0.U64, |s, x| s + x) + blocks.fold(0.U64, |s, x| s + x)
}
