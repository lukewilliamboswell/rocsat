# Q4: what does the bounds check + Try wrapper on List.get cost in a hot loop?
#
# There is no public unchecked accessor, so we compare the shapes actually available:
#   idx    - while loop, random-access style: $arr.get($i)?
#   idxq   - same, but `?? 0` instead of `?`
#   iter   - sequential `for x in $arr`
#   fold   - sequential $arr.fold
#   arith  - no list access at all (loop floor)
#
# Same total element count in every mode: reps passes over a list of m elements.

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    reps = U64.from_str(args.get(2)?)?

    arr = List.repeat(3.U64, m)

    total =
        if mode == "idx" {
            run_idx(arr, m, reps)?
        } else if mode == "idxq" {
            Ok(run_idxq(arr, m, reps))?
        } else if mode == "iter" {
            Ok(run_iter(arr, reps))?
        } else if mode == "fold" {
            Ok(run_fold(arr, reps))?
        } else {
            Ok(run_arith(m, reps))?
        }

    echo!("mode=${mode} m=${m.to_str()} reps=${reps.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}

run_idx = |arr, m, reps| {
    var $acc = 0.U64
    var $r = 0.U64
    while $r < reps {
        var $i = 0.U64
        while $i < m {
            $acc = $acc + arr.get($i)?
            $i = $i + 1
        }
        $r = $r + 1
    }
    Ok($acc)
}

run_idxq = |arr, m, reps| {
    var $acc = 0.U64
    var $r = 0.U64
    while $r < reps {
        var $i = 0.U64
        while $i < m {
            $acc = $acc + (arr.get($i) ?? 0)
            $i = $i + 1
        }
        $r = $r + 1
    }
    $acc
}

run_iter = |arr, reps| {
    var $acc = 0.U64
    var $r = 0.U64
    while $r < reps {
        for x in arr {
            $acc = $acc + x
        }
        $r = $r + 1
    }
    $acc
}

run_fold = |arr, reps| {
    var $acc = 0.U64
    var $r = 0.U64
    while $r < reps {
        $acc = $acc + arr.fold(0.U64, |s, x| s + x)
        $r = $r + 1
    }
    $acc
}

run_arith = |m, reps| {
    var $acc = 0.U64
    var $r = 0.U64
    while $r < reps {
        var $i = 0.U64
        while $i < m {
            $acc = $acc + 3
            $i = $i + 1
        }
        $r = $r + 1
    }
    $acc
}
