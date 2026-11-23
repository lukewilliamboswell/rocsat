# SIMD DIMACS line scanning

The experiment uses Roc's `U8x16` to find LF in 16 contiguous bytes at a time.
The first set bit locates the newline. A scalar loop handles the final partial
chunk. Comments and ignored header lines go through this scanner. The solver
still sees the same formulas.

On Apple Silicon with Roc `0.1.0_RC1` and `--opt=speed`, the second benchmark
run produced these median CLI times over 11 timed runs per binary.

| Input | Scalar | SIMD | Speedup |
|---|---:|---:|---:|
| 16 MiB of 8-byte comment lines | 16.60 ms | 11.73 ms | 1.42× |
| 16 MiB of 128-byte comment lines | 14.69 ms | 8.37 ms | 1.76× |
| 16 MiB of 1,024-byte comment lines | 13.28 ms | 8.14 ms | 1.63× |
| Two-million-clause implication chain, parse | 141.96 ms | 137.38 ms | 1.03× |
| Cellular automata CNF, parse | 226.97 ms | 215.25 ms | 1.05× |
| Sorting networks CNF, parse | 197.44 ms | 185.58 ms | 1.06× |
| Two-million-clause implication chain, solve | 472.37 ms | 470.84 ms | 1.00× |

The first run showed the same pattern on the comment fixtures. Workloads that
spend substantial time scanning comment bytes benefit. The implication chain
solve was effectively flat. Two-watched-literal propagation fetches assignments
through literal IDs and can change those assignments as it walks, so this
contiguous scanning technique does not directly apply to that loop.

## Reproduce

With `ROC_BIN` set to the RC1 compiler, build the scalar and experimental
binaries in separate worktrees. Pass any additional DIMACS files after the
binary paths. The script generates the comment fixtures, alternates binary
order, and checks that the parse output matches.

```sh
git worktree add --detach ../rocsat-scalar 0.0.1
make -C ../rocsat-scalar build
make build
uv run --script spike/simd-dimacs/bench.py ../rocsat-scalar/src/rocsat src/rocsat
```
