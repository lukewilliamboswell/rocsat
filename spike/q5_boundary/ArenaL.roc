# Cross-module helpers over separate lists.

ArenaL :: [].{
    step : List(U64), List(U64), U64, U64, U64 -> (List(U64), List(U64))
    step = |b, c, lit, cap, i| {
        k = c.get(lit) ?? 0
        (b.set((lit * cap) + k, i) ?? b, c.set(lit, k + 1) ?? c)
    }

    step_try : List(U64), List(U64), U64, U64, U64 -> Try((List(U64), List(U64)), [OutOfBounds, ..])
    step_try = |b, c, lit, cap, i| {
        k = c.get(lit)?
        b2 = b.set((lit * cap) + k, i)?
        c2 = c.set(lit, k + 1)?
        Ok((b2, c2))
    }
}
