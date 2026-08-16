# `List.reserve(list, k)` sets capacity to exactly `len + k` instead of taking the
# geometric growth path, so calling it periodically while appending is quadratic.
#
#   roc build --opt=speed reserve.roc
#   ./reserve reserve 1000000 4096   #  124 ms
#   ./reserve reserve 2000000 4096   #  512 ms   (4.1x for 2x n)
#   ./reserve reserve 4000000 4096   # 2793 ms   (5.5x)
#   ./reserve append  4000000 4096   #   12 ms   (plain append, geometric)
#   ./reserve manual  4000000 4096   #   13 ms   (hand-tracked doubling reserve)
#
# From src/builtins/list.zig: a requested capacity that is not exactly `old_capacity + 1`
# is trusted verbatim, so `reserve` never doubles. `List.append` is
# `reserve(list, 1) + list_append_unsafe`, which does hit the geometric path — the one
# call a user would reach for to pre-allocate is the one that is not amortised.

main! = |args| {
    mode = args.get(0)?
    n = U64.from_str(args.get(1)?)?
    k = U64.from_str(args.get(2)?)?

    len =
        if mode == "reserve" {
            var $xs = []
            var $i = 0.U64
            while $i < n {
                if $i % k == 0 {
                    $xs = $xs.reserve(k)
                }
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len()
        } else if mode == "append" {
            var $xs = []
            var $i = 0.U64
            while $i < n {
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len()
        } else {
            # what `reserve` would do if it grew geometrically
            var $xs = List.with_capacity(k)
            var $cap = k
            var $i = 0.U64
            while $i < n {
                if $i == $cap {
                    $cap = $cap * 2
                    $xs = $xs.reserve($cap - $i)
                }
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len()
        }

    echo!("mode=${mode} n=${n.to_str()} k=${k.to_str()} len=${len.to_str()}\n")
    Ok({})
}
