# Q2: does appending into a nested List(List(U64)) mutate the inner list in place?
#
# This is the watch-list question. M inner lists, N appends spread across them.
#   in-place => O(N), linear in N
#   clone    => O(N * avg_inner_len) = O(N^2/M), quadratic in N
#
# modes:
#   update  - $w.update(lit, |inner| inner.append(v))
#   getset  - inner = $w.get(lit); $w.set(lit, inner.append(v))
#   record  - same as update, but the nested list lives in a record field (solver-shaped)
#   flat    - flat single List(U64) baseline, for a speed reference

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    n = U64.from_str(args.get(2)?)?

    total =
        if mode == "update" {
            run_update(m, n)?
        } else if mode == "getset" {
            run_getset(m, n)?
        } else if mode == "record" {
            run_record(m, n)?
        } else {
            run_flat(m, n)?
        }

    echo!("mode=${mode} m=${m.to_str()} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}

run_update = |m, n| {
    var $w = List.repeat([], m)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        $w = $w.update(lit, |inner| inner.append($i))?
        $i = $i + 1
    }
    Ok(checksum($w))
}

run_getset = |m, n| {
    var $w = List.repeat([], m)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        inner = $w.get(lit)?
        $w = $w.set(lit, inner.append($i))?
        $i = $i + 1
    }
    Ok(checksum($w))
}

run_record = |m, n| {
    var $st = { watches: List.repeat([], m), trail: List.with_capacity(16) }
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        $st = { ..$st, watches: $st.watches.update(lit, |inner| inner.append($i))? }
        $i = $i + 1
    }
    Ok(checksum($st.watches))
}

run_flat = |m, n| {
    var $w = List.with_capacity(n)
    var $i = 0.U64
    while $i < n {
        $w = $w.append($i % m)
        $i = $i + 1
    }
    Ok($w.len() + $w.fold(0.U64, |s, x| s + x))
}

checksum = |w|
    w.fold(0.U64, |s, inner| s + inner.len() + inner.fold(0.U64, |s2, x| s2 + x))
