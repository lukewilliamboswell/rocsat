# Q7 (Track B Q5): allocation, growth and startup costs.
#
# usage: alloc <mode> <n> [k]
#   repeat        List.repeat(0.U32, n)                                    (zero-filled array)
#   repeat64      List.repeat(0.U64, n)
#   wcap_append   List.with_capacity(n) then n appends                      (pre-sized fill)
#   append        [] then n appends                                         (geometric growth)
#   reserve_k     [] then, every k appends, reserve(k) first                (chunked reserve)
#   reserve_geo   [] then reserve(cap) whenever len reaches cap (cap doubles; tracked by hand)
#   set_then_append  with_capacity(n); for each i: set(0, i) then append   (does `set` keep capacity?)
#   arena_grow    simulate parsing: append n literals in clauses of 5 words with a 2-word header, from []
#   arena_reserve same, but with_capacity(n + n/5*2) up front
#   startup_k     allocate k solver arrays of n elements each (List.repeat) and touch one element of each
#   grow_shrink   append n, drop_last(n/2), append n/2 again (does capacity survive drop_last?)
#   release       append n, release_excess_capacity, then append n more   (cost of shrink + regrow)
# Prints a checksum so nothing is dead code.

main! = |args| {
    mode = args.get(0)?
    n = U64.from_str(args.get(1)?)?
    k = U64.from_str(args.get(2) ?? "1000") ?? 1000

    ck =
        if mode == "repeat" {
            xs = List.repeat(0.U32, n)
            xs.len() + (xs.get(n / 2) ?? 1).to_u64()
        } else if mode == "repeat64" {
            xs = List.repeat(0.U64, n)
            xs.len() + (xs.get(n / 2) ?? 1)
        } else if mode == "wcap_append" {
            var $xs = List.with_capacity(n)
            var $i = 0.U64
            while $i < n {
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len() + ($xs.get(n / 2) ?? 1).to_u64()
        } else if mode == "append" {
            var $xs = []
            var $i = 0.U64
            while $i < n {
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len() + ($xs.get(n / 2) ?? 1).to_u64()
        } else if mode == "reserve_k" {
            var $xs = []
            var $i = 0.U64
            while $i < n {
                if $i % k == 0 {
                    $xs = $xs.reserve(k)
                }
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len() + ($xs.get(n / 2) ?? 1).to_u64()
        } else if mode == "reserve_geo" {
            var $xs = List.with_capacity(k)
            var $cap = k
            var $i = 0.U64
            while $i < n {
                if $i == $cap {
                    $xs = $xs.reserve($cap)
                    $cap = $cap * 2
                }
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len() + ($xs.get(n / 2) ?? 1).to_u64()
        } else if mode == "set_then_append" {
            var $xs = List.with_capacity(n)
            $xs = $xs.append(0.U32)
            var $i = 1.U64
            while $i < n {
                $xs = $xs.set(0, $i.to_u32_wrap()) ?? $xs
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len() + ($xs.get(0) ?? 1).to_u64()
        } else if mode == "arena_grow" {
            arena_fill([], n)
        } else if mode == "arena_reserve" {
            arena_fill(List.with_capacity(n + ((n / 5) * 2)), n)
        } else if mode == "startup_k" {
            var $acc = 0.U64
            var $j = 0.U64
            while $j < k {
                xs = List.repeat($j.to_u32_wrap(), n)
                $acc = $acc + (xs.get(n - 1) ?? 0).to_u64()
                $j = $j + 1
            }
            $acc
        } else if mode == "grow_shrink" {
            var $xs = []
            var $i = 0.U64
            while $i < n {
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs = $xs.drop_last(n / 2)
            $i = 0
            while $i < n / 2 {
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len() + ($xs.get(n / 2) ?? 1).to_u64()
        } else if mode == "release" {
            var $xs = []
            var $i = 0.U64
            while $i < n {
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs = $xs.release_excess_capacity()
            $i = 0
            while $i < n {
                $xs = $xs.append($i.to_u32_wrap())
                $i = $i + 1
            }
            $xs.len() + ($xs.get(n / 2) ?? 1).to_u64()
        } else {
            return Err(UnknownMode)
        }

    echo!("mode=${mode} n=${n.to_str()} k=${k.to_str()} checksum=${ck.to_str()}\n")
    Ok({})
}

# append n literals as clauses of 5 literals, each preceded by a 2-word header
arena_fill = |arena0, n| {
    var $arena = arena0
    var $i = 0.U64
    while $i < n {
        if $i % 5 == 0 {
            $arena = $arena.append(5.U32)
            $arena = $arena.append(0.U32)
        }
        $arena = $arena.append($i.to_u32_wrap())
        $i = $i + 1
    }
    $arena.len() + ($arena.get(n / 2) ?? 1).to_u64()
}
