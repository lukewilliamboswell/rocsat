# Void module: a namespace of functions over a plain state record.
# Cross-module counterpart of the same-module functions in main.roc.

Arena :: [].{
    step : { blocks : List(U64), counts : List(U64) }, U64, U64, U64 -> { blocks : List(U64), counts : List(U64) }
    step = |st, lit, cap, i| {
        c = st.counts.get(lit) ?? 0
        b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
        cs = st.counts.set(lit, c + 1) ?? st.counts
        { blocks: b, counts: cs }
    }

    step_try : { blocks : List(U64), counts : List(U64) }, U64, U64, U64 -> Try({ blocks : List(U64), counts : List(U64) }, [OutOfBounds, ..])
    step_try = |st, lit, cap, i| {
        c = st.counts.get(lit)?
        b = st.blocks.set((lit * cap) + c, i)?
        cs = st.counts.set(lit, c + 1)?
        Ok({ blocks: b, counts: cs })
    }

    step_tuple : { blocks : List(U64), counts : List(U64) }, U64, U64, U64 -> ({ blocks : List(U64), counts : List(U64) }, U64)
    step_tuple = |st, lit, cap, i| {
        c = st.counts.get(lit) ?? 0
        b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
        cs = st.counts.set(lit, c + 1) ?? st.counts
        ({ blocks: b, counts: cs }, c + 1)
    }

    count_of : { blocks : List(U64), counts : List(U64) }, U64 -> U64
    count_of = |st, lit| st.counts.get(lit) ?? 0

    run : { blocks : List(U64), counts : List(U64) }, U64, U64, U64, U64 -> { blocks : List(U64), counts : List(U64) }
    run = |st, i, n, m, cap| {
        if i >= n {
            st
        } else {
            run(step(st, i % m, cap, i), i + 1, n, m, cap)
        }
    }
}
