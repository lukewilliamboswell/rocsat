app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.22.0/F1JVZPYfWP71s8vk6tHcV1Qx1Ef6CZkwswGoCn8VHZmL.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Stderr

version = "0.0.0"

usage = Str.join_with(
    [
        "usage: rocsat <command> [args]",
        "",
        "commands:",
        "  version           print the version",
        "  help              print this message",
    ],
    "\n",
)

main! : List(OsStr) => Try({}, _)
main! = |args| {
    cmd = args.drop_first(1).map(OsStr.display)
    match cmd {
        ["version"] => Stdout.line!("rocsat ${version}")
        ["help"] => Stdout.line!(usage)
        _ => {
            Stderr.line!(usage)?
            Err(Exit(1))
        }
    }
}
