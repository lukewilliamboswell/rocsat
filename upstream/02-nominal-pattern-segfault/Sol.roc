# The record pattern `Sol.{ blocks }` omits `counts` and has no `..`, so it is a type error.
# Checked on its own (`roc check Sol.roc`) the compiler reports it correctly, every time.
Sol := { blocks : List(U64), counts : List(U64) }.{
    new : U64 -> Sol
    new = |m| Sol.{ blocks: List.repeat(0.U64, m), counts: List.repeat(0.U64, m) }

    total : Sol -> U64
    total = |Sol.{ blocks }| blocks.fold(0.U64, |s, x| s + x)
}
