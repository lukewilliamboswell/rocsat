# A four-line, same-module, pure helper (`step`) is not inlined into the hot loop that
# calls it, in either the `while` or the self-recursive form. The call costs ~6.6 ns,
# three times as much as the loop body it wraps.
#
#   roc build --opt=speed inline_vs_call.roc
#   ./inline_vs_call inline_loop 1000 4000 3200000   #  6.5 ms of loop  (body written out)
#   ./inline_vs_call inline_rec  1000 4000 3200000   #  6.8 ms          (body written out)
#   ./inline_vs_call call_loop   1000 4000 3200000   # 27.6 ms          (same body, via `step`)
#   ./inline_vs_call call_rec    1000 4000 3200000   # 27.5 ms          (same body, via `step`)
#
# Loop time = the n=3,200,000 run minus an n=0 run, min of 5. The gap is 21 ms over
# 3.2 M calls = 6.6 ns per call, against a ~2 ns loop body.
#
# Every mode does the same 3.2 M iterations of {modulo, one indexed read, two indexed
# writes} over the same two lists, all mutated in place (checksums are identical). The
# only difference is whether those four lines sit in the loop or behind a call that
# returns the two lists as a tuple.
#
# Inlining `step` here would remove the tuple round-trip entirely. In a solver's
# propagate loop this is the difference between a helper-structured module and one
# hand-flattened into a single function, which is a bad trade to have to make.

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    cap = U64.from_str(args.get(2)?)?
    n = U64.from_str(args.get(3)?)?

    (xs, ys) =
        if mode == "call_rec" {
            loop_rec(List.repeat(0.U64, m * cap), List.repeat(0.U64, m), 0, n, m, cap)
        } else if mode == "call_loop" {
            var $xs = List.repeat(0.U64, m * cap)
            var $ys = List.repeat(0.U64, m)
            var $i = 0.U64
            while $i < n {
                (a, b) = step($xs, $ys, $i % m, cap, $i)
                $xs = a
                $ys = b
                $i = $i + 1
            }
            ($xs, $ys)
        } else if mode == "inline_loop" {
            var $xs = List.repeat(0.U64, m * cap)
            var $ys = List.repeat(0.U64, m)
            var $i = 0.U64
            while $i < n {
                lit = $i % m
                k = $ys.get(lit) ?? 0
                $xs = $xs.set((lit * cap) + k, $i) ?? $xs
                $ys = $ys.set(lit, k + 1) ?? $ys
                $i = $i + 1
            }
            ($xs, $ys)
        } else {
            loop_rec_inline(List.repeat(0.U64, m * cap), List.repeat(0.U64, m), 0, n, m, cap)
        }

    total = ys.fold(0.U64, |s, x| s + x) + xs.fold(0.U64, |s, x| s + x)
    echo!("mode=${mode} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}

step = |xs, ys, lit, cap, i| {
    k = ys.get(lit) ?? 0
    (xs.set((lit * cap) + k, i) ?? xs, ys.set(lit, k + 1) ?? ys)
}

loop_rec = |xs, ys, i, n, m, cap|
    if i >= n {
        (xs, ys)
    } else {
        (a, b) = step(xs, ys, i % m, cap, i)
        loop_rec(a, b, i + 1, n, m, cap)
    }

loop_rec_inline = |xs, ys, i, n, m, cap|
    if i >= n {
        (xs, ys)
    } else {
        lit = i % m
        k = ys.get(lit) ?? 0
        a = xs.set((lit * cap) + k, i) ?? xs
        b = ys.set(lit, k + 1) ?? ys
        loop_rec_inline(a, b, i + 1, n, m, cap)
    }
