# Appending into an inner list of a List(List(U64)) clones that inner list every time,
# so filling M lists with N total elements is O(N^2 / M) instead of O(N).
#
#   roc build --opt=speed nested_list.roc
#   ./nested_list update 1000 400000    #   35 ms
#   ./nested_list update 1000 800000    #   98 ms   (2.8x for 2x n)
#   ./nested_list update 1000 1600000   #  371 ms   (3.8x)
#   ./nested_list update 1000 3200000   # 1625 ms   (4.4x)
#   ./nested_list flat   1000 3200000   #   10 ms   (linear reference)
#
# `getset` (List.get then List.set) behaves identically to `update`, which matches the
# Builtin.roc definition:
#
#   update = |list, index, func|
#       Ok(list_replace_unsafe(list, index, func(list_get_unsafe(list, index))).list)
#
# `list_get_unsafe` hands `func` a second reference to the inner list, so the `append`
# inside `func` sees a refcount of 2 and clones. The inner list is dead immediately
# afterwards, so nothing observes the copy.

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    n = U64.from_str(args.get(2)?)?

    total =
        if mode == "update" {
            var $w = List.repeat([], m)
            var $i = 0.U64
            while $i < n {
                $w = $w.update($i % m, |inner| inner.append($i))?
                $i = $i + 1
            }
            $w.fold(0.U64, |s, inner| s + inner.len() + inner.fold(0.U64, |s2, x| s2 + x))
        } else if mode == "getset" {
            var $w = List.repeat([], m)
            var $i = 0.U64
            while $i < n {
                lit = $i % m
                inner = $w.get(lit)?
                $w = $w.set(lit, inner.append($i))?
                $i = $i + 1
            }
            $w.fold(0.U64, |s, inner| s + inner.len() + inner.fold(0.U64, |s2, x| s2 + x))
        } else {
            # one flat list holding the same values: the linear reference
            var $w = List.with_capacity(n)
            var $i = 0.U64
            while $i < n {
                $w = $w.append($i)
                $i = $i + 1
            }
            $w.len() + $w.fold(0.U64, |s, x| s + x)
        }

    echo!("mode=${mode} m=${m.to_str()} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}
