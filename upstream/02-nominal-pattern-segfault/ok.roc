# Sol.roc with the pattern fixed (`Sol.{ blocks, .. }`) compiles and runs; drop this in
# as Sol.roc to confirm the rest of the reproducer is sound.
Sol := { blocks : List(U64), counts : List(U64) }.{
    new : U64 -> Sol
    new = |m| Sol.{ blocks: List.repeat(0.U64, m), counts: List.repeat(0.U64, m) }

    total : Sol -> U64
    total = |Sol.{ blocks, .. }| blocks.fold(0.U64, |s, x| s + x)
}
