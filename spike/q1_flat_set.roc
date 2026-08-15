# Q1: does `var $arr = ...; $arr = $arr.set(i, v)?` mutate in place?
#
# Method: N writes into a list of size M, cycling the index.
#   in-place  => time ~ O(N), flat in M
#   cloning   => time ~ O(N*M), linear in M
# M and N come from argv so nothing is constant-folded at compile time.

main! = |args| {
    m = U64.from_str(args.get(0)?)?
    n = U64.from_str(args.get(1)?)?

    var $arr = List.repeat(0.U64, m)
    var $i = 0.U64

    while $i < n {
        idx = $i % m
        $arr = $arr.set(idx, $i)?
        $i = $i + 1
    }

    # consume the result so the loop can't be discarded
    total = $arr.fold(0.U64, |s, x| s + x)
    echo!("m=${m.to_str()} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}
