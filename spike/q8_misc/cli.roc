app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Stderr
import pf.Path
import pf.Utc

main! : List(OsStr) => Try({}, _)
main! = |args| {
    t0 = Utc.now!()
    path_str =
        match args.drop_first(1) {
            [a, ..] => OsStr.display(a)
            [] => "cli.roc"
        }
    n_str = match args.drop_first(2) { [b, ..] => OsStr.display(b) _ => "3200000" }
    n = U64.from_str(n_str)?
    path : Path
    path = Path.utf8(path_str)
    bytes = path.read_bytes!()?
    t1 = Utc.now!()
    # the q3 workload: m=1000 cap=4000, n appends
    (blocks, counts) = churn(1000, 4000, n)?
    ck = counts.fold(0.U64, |s, x| s + x) + blocks.fold(0.U64, |s, x| s + x)
    t2 = Utc.now!()
    Stdout.line!("read ${bytes.len().to_str()} bytes in ${Utc.delta_as_nanos(t1, t0).to_str()} ns; loop checksum=${ck.to_str()} in ${Utc.delta_as_nanos(t2, t1).to_str()} ns")?
    Stderr.line!("to stderr")?
    if n == 0 { Err(Exit(3)) } else { Ok({}) }
}

churn = |m, cap, n| {
    var $blocks = List.repeat(0.U64, m * cap)
    var $counts = List.repeat(0.U64, m)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $counts.get(lit)?
        $blocks = $blocks.set((lit * cap) + c, $i)?
        $counts = $counts.set(lit, c + 1)?
        $i = $i + 1
    }
    Ok(($blocks, $counts))
}
