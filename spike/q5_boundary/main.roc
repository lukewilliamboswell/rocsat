# Q5 (Track B Q1): does in-place mutation survive function and module boundaries?
#
# Same workload as q3_flatwatch `record` mode: m blocks x cap slots in one flat
# List(U64) plus a List(U64) of per-block counts; n appends spread over blocks.
# The inner update is moved behind different kinds of boundary.
#
# modes:
#   inline     - baseline: everything in one while loop (q3 `record`)
#   fn         - same-module function  step(st, lit, cap, i) -> st
#   fn_try     - same-module function returning Try(st, err), unwrapped with `?`
#   fn_tuple   - same-module function returning (st, U64)
#   fn_read    - same-module read-only helper count_of(st, lit) called BEFORE the mutation
#   rec        - same-module self-recursive loop threading st
#   mod        - Arena.step  (void module, plain record)      cross-module
#   mod_try    - Arena.step_try                               cross-module, Try
#   mod_tuple  - Arena.step_tuple                             cross-module, tuple
#   mod_read   - Arena.count_of read helper before mutation   cross-module
#   mod_rec    - Arena.run recursive loop                     cross-module recursion
#   nom        - Sol.step, nominal type with methods, `st.step(...)` dispatch
#   nom_read   - Sol.count_of read helper before mutation
#   nom_rec    - Sol.run recursive loop

import Arena
import Sol

main! = |args| {
    mode = args.get(0)?
    m = U64.from_str(args.get(1)?)?
    cap = U64.from_str(args.get(2)?)?
    n = U64.from_str(args.get(3)?)?

    total =
        if mode == "inline" {
            run_inline(m, cap, n)?
        } else if mode == "fn" {
            run_fn(m, cap, n)?
        } else if mode == "fn_try" {
            run_fn_try(m, cap, n)?
        } else if mode == "fn_tuple" {
            run_fn_tuple(m, cap, n)?
        } else if mode == "fn_read" {
            run_fn_read(m, cap, n)?
        } else if mode == "fn_read_pat" {
            run_fn_read_pat(m, cap, n)?
        } else if mode == "fn_read_list" {
            run_fn_read_list(m, cap, n)?
        } else if mode == "fn_read_both" {
            run_fn_read_both(m, cap, n)?
        } else if mode == "fn_read_fn" {
            run_fn_read_fn(m, cap, n)?
        } else if mode == "fn_ok" {
            run_fn_ok(m, cap, n)?
        } else if mode == "fn_q1" {
            run_fn_q1(m, cap, n)?
        } else if mode == "fn_q2" {
            run_fn_q2(m, cap, n)?
        } else if mode == "fn_q3" {
            run_fn_q3(m, cap, n)?
        } else if mode == "fn_m" {
            run_fn_m(m, cap, n)?
        } else if mode == "fn_read_qq" {
            run_fn_read_qq(m, cap, n)?
        } else if mode == "fn_read_thread" {
            run_fn_read_thread(m, cap, n)?
        } else if mode == "fn_read_twice" {
            run_fn_read_twice(m, cap, n)?
        } else if mode == "fn_ret" {
            run_fn_ret(m, cap, n)?
        } else if mode == "rec_q" {
            run_rec_q(m, cap, n)?
        } else if mode == "fn_list_q" {
            run_fn_list_q(m, cap, n)?
        } else if mode == "fn_ident" {
            run_fn_ident(m, cap, n)?
        } else if mode == "fn_read_alias" {
            run_fn_read_alias(m, cap, n)?
        } else if mode == "fn_read_full" {
            run_fn_read_full(m, cap, n)?
        } else if mode == "fn_read_setq" {
            run_fn_read_setq(m, cap, n)?
        } else if mode == "fn_read_destr" {
            run_fn_read_destr(m, cap, n)?
        } else if mode == "nest" {
            run_nest(m, cap, n)?
        } else if mode == "nest_inline" {
            run_nest_inline(m, cap, n)?
        } else if mode == "deep" {
            run_deep(m, cap, n)?
        } else if mode == "after" {
            run_after(m, cap, n)?
        } else if mode == "nest_var" {
            run_nest_var(m, cap, n)?
        } else if mode == "seq" {
            run_seq(m, cap, n)?
        } else if mode == "seq_var" {
            run_seq_var(m, cap, n)?
        } else if mode == "try_var" {
            run_try_var(m, cap, n)?
        } else if mode == "pipe" {
            run_pipe(m, cap, n)?
        } else if mode == "x_inline" {
            run_x_inline(m, cap, n)?
        } else if mode == "x_helpers" {
            run_x_helpers(m, cap, n)?
        } else if mode == "x_mod" {
            run_x_mod(m, cap, n)?
        } else if mode == "x_two" {
            run_x_two(m, cap, n)?
        } else if mode == "y_qq" {
            run_y_qq(m, cap, n)?
        } else if mode == "y_split" {
            run_y_split(m, cap, n)?
        } else if mode == "y_seeded" {
            run_y_seeded(m, cap, n)?
        } else if mode == "y_prime" {
            run_y_prime(m, cap, n)?
        } else if mode == "rec" {
            run_rec(m, cap, n)?
        } else if mode == "mod" {
            run_mod(m, cap, n)?
        } else if mode == "mod_try" {
            run_mod_try(m, cap, n)?
        } else if mode == "mod_tuple" {
            run_mod_tuple(m, cap, n)?
        } else if mode == "mod_read" {
            run_mod_read(m, cap, n)?
        } else if mode == "mod_rec" {
            run_mod_rec(m, cap, n)?
        } else if mode == "nom" {
            run_nom(m, cap, n)?
        } else if mode == "nom_read" {
            run_nom_read(m, cap, n)?
        } else if mode == "nom_rec" {
            run_nom_rec(m, cap, n)?
        } else {
            return Err(UnknownMode)
        }

    echo!("mode=${mode} m=${m.to_str()} cap=${cap.to_str()} n=${n.to_str()} checksum=${total.to_str()}\n")
    Ok({})
}

new_state = |m, cap| { blocks: List.repeat(0.U64, m * cap), counts: List.repeat(0.U64, m) }

checksum = |st| st.counts.fold(0.U64, |s, x| s + x) + st.blocks.fold(0.U64, |s, x| s + x)

# ---------------------------------------------------------------- baseline

run_inline = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit)?
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# ---------------------------------------------------------------- same module

# (a) plain function, state in, state out. Errors turned into no-ops so the
# signature is exactly `st -> st`.
step = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
    cs = st.counts.set(lit, c + 1) ?? st.counts
    { blocks: b, counts: cs }
}

run_fn = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# (c) returns Try(st, _)
step_try = |st, lit, cap, i| {
    c = st.counts.get(lit)?
    b = st.blocks.set((lit * cap) + c, i)?
    cs = st.counts.set(lit, c + 1)?
    Ok({ blocks: b, counts: cs })
}

run_fn_try = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_try($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# (d) returns a tuple (st, count_after)
step_tuple = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
    cs = st.counts.set(lit, c + 1) ?? st.counts
    ({ blocks: b, counts: cs }, c + 1)
}

run_fn_tuple = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    var $acc = 0.U64
    while $i < n {
        (st2, c) = step_tuple($st, $i % m, cap, $i)
        $st = st2
        $acc = $acc + c
        $i = $i + 1
    }
    Ok(checksum($st) + $acc)
}

# (f) read-only helper taking the whole state, called before the mutation.
# This is the shape that killed List.update: if the callee holds a second
# reference to `st` while the caller mutates, the 32MB list gets cloned.
count_of = |st, lit| st.counts.get(lit) ?? 0

run_fn_read = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# --- isolating the fn_read failure ---

# read helper that destructures the record in its parameter pattern (nom_read shape)
count_of_pat = |{ counts, .. }, lit| counts.get(lit) ?? 0

run_fn_read_pat = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of_pat($st, lit)
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# read helper that takes only the list, not the record
count_of_list = |counts, lit| counts.get(lit) ?? 0

run_fn_read_list = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of_list($st.counts, lit)
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# read helper that reads BOTH fields (does touching blocks matter?)
count_of_both = |st, lit| (st.counts.get(lit) ?? 0) + (st.blocks.get(0) ?? 0)

run_fn_read_both = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of_both($st, lit)
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# read helper, but the mutation is done by a function taking the record too
run_fn_read_fn = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        $st = write_at($st, lit, cap, c, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

write_at = |st, lit, cap, c, i| {
    b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
    cs = st.counts.set(lit, c + 1) ?? st.counts
    { blocks: b, counts: cs }
}

# --- isolating the fn_try failure ---

# returns Try but uses ?? internally: is it the return type or the `?` inside?
step_ok = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
    cs = st.counts.set(lit, c + 1) ?? st.counts
    Ok({ blocks: b, counts: cs })
}

run_fn_ok = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_ok($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# uses `?` on the get only, `??` on the sets
step_q1 = |st, lit, cap, i| {
    c = st.counts.get(lit)?
    b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
    cs = st.counts.set(lit, c + 1) ?? st.counts
    Ok({ blocks: b, counts: cs })
}

run_fn_q1 = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_q1($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# uses `?` on the sets only, `??` on the get
step_q2 = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    b = st.blocks.set((lit * cap) + c, i)?
    cs = st.counts.set(lit, c + 1)?
    Ok({ blocks: b, counts: cs })
}

run_fn_q2 = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_q2($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# `?` on sets, but destructure the record in the parameter first
step_q3 = |{ blocks, counts }, lit, cap, i| {
    c = counts.get(lit) ?? 0
    b = blocks.set((lit * cap) + c, i)?
    cs = counts.set(lit, c + 1)?
    Ok({ blocks: b, counts: cs })
}

run_fn_q3 = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_q3($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# explicit match instead of `?` — same control flow, no sugar
step_m = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    match st.blocks.set((lit * cap) + c, i) {
        Err(e) => Err(e)
        Ok(b) =>
            match st.counts.set(lit, c + 1) {
                Err(e) => Err(e)
                Ok(cs) => Ok({ blocks: b, counts: cs })
            }
    }
}

run_fn_m = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_m($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# R1: fn_read, but the caller uses `??` for the sets (no `?` anywhere in the loop)
run_fn_read_qq = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# R4: read helper that threads the record back out: (st, c)
count_of_thread = |st, lit| (st, st.counts.get(lit) ?? 0)

run_fn_read_thread = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        (st2, c) = count_of_thread($st, lit)
        $st = { ..st2, blocks: st2.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# R6: same as R1 but the sets are inline in a *nested block* after the read... no:
# instead, read helper called and the result immediately used by another function
# that does NOT take the record: is it "record passed to any function" or the pattern?
run_fn_read_twice = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        c2 = count_of($st, lit)
        $st = write_at($st, lit, cap, (c + c2) / 2, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# T2: explicit `return` inside the callee, `??` for the list ops
step_ret = |st, lit, cap, i| {
    if lit > cap * 1000 {
        return Err(Impossible)
    }
    c = st.counts.get(lit) ?? 0
    b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
    cs = st.counts.set(lit, c + 1) ?? st.counts
    Ok({ blocks: b, counts: cs })
}

run_fn_ret = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_ret($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# T4: `?` inside the callee, but the callee is the recursive loop itself (state is
# a param, `?` on the get) — is recursion + `?` also broken?
loop_rec_q = |st, i, n, m, cap| {
    if i >= n {
        Ok(st)
    } else {
        lit = i % m
        c = st.counts.get(lit)?
        b = st.blocks.set((lit * cap) + c, i)?
        cs = st.counts.set(lit, c + 1)?
        loop_rec_q({ blocks: b, counts: cs }, i + 1, n, m, cap)
    }
}

run_rec_q = |m, cap, n| {
    st = loop_rec_q(new_state(m, cap), 0.U64, n, m, cap)?
    Ok(checksum(st))
}

# T5: `?` inside a callee that receives ONLY the list, not the record
set_q = |blocks, idx, v| {
    b = blocks.set(idx, v)?
    Ok(b)
}

run_fn_list_q = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit)?
        $st = { ..$st, blocks: set_q($st.blocks, (lit * cap) + c, $i)? }
        $st = { ..$st, counts: set_q($st.counts, lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# V1: identity function on the record, then inline field mutation on the result
identity = |st| st

run_fn_ident = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        st2 = identity($st)
        c = st2.counts.get(lit)?
        $st = { ..st2, blocks: st2.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# V2: alias the var to a plain local first
run_fn_read_alias = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        s = $st
        c = count_of(s, lit)
        $st = { ..s, blocks: s.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# V4: read helper, then rebuild the whole record without `..` spread
run_fn_read_full = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        $st = { blocks: $st.blocks.set((lit * cap) + c, $i)?, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# V3: read helper, then mutation via a list-only function
run_fn_read_setq = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        $st = { ..$st, blocks: set_q($st.blocks, (lit * cap) + c, $i)? }
        $st = { ..$st, counts: set_q($st.counts, lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# V6: read helper, then destructure the record into locals and mutate those
run_fn_read_destr = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        { blocks, counts } = $st
        b = blocks.set((lit * cap) + c, $i)?
        cs = counts.set(lit, c + 1)?
        $st = { blocks: b, counts: cs }
        $i = $i + 1
    }
    Ok(checksum($st))
}

# N1: inside a callee: read helper on st, then hand st to a write helper
step_nest = |st, lit, cap, i| {
    c = count_of(st, lit)
    write_at(st, lit, cap, c, i)
}

run_nest = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_nest($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# N2: inside a callee: read helper on st, then inline mutation of st's fields
step_nest_inline = |st, lit, cap, i| {
    c = count_of(st, lit)
    b = st.blocks.set((lit * cap) + c, i) ?? st.blocks
    cs = st.counts.set(lit, c + 1) ?? st.counts
    { blocks: b, counts: cs }
}

run_nest_inline = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_nest_inline($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# N3: three levels deep, each consume-and-return, cross-module at the bottom
level_a = |st, lit, cap, i| level_b(st, lit, cap, i)
level_b = |st, lit, cap, i| Arena.step(st, lit, cap, i)

run_deep = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = level_a($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# N4: a callee that mutates and ALSO calls a read helper afterwards on the new state
step_after = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    st2 = write_at(st, lit, cap, c, i)
    _ = count_of(st2, lit)
    st2
}

run_after = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_after($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# W1: like `nest` (read helper then write helper) but through a `var` local
step_nest_var = |st, lit, cap, i| {
    var $s = st
    c = count_of($s, lit)
    $s = write_at($s, lit, cap, c, i)
    $s
}

run_nest_var = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_nest_var($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# W2: two sequential write helpers on immutable bindings, no read helper
set_block = |st, idx, v| { ..st, blocks: st.blocks.set(idx, v) ?? st.blocks }
set_count = |st, idx, v| { ..st, counts: st.counts.set(idx, v) ?? st.counts }

step_seq = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    st2 = set_block(st, (lit * cap) + c, i)
    st3 = set_count(st2, lit, c + 1)
    st3
}

run_seq = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_seq($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# W3: same as W2 through a `var` local
step_seq_var = |st, lit, cap, i| {
    var $s = st
    c = $s.counts.get(lit) ?? 0
    $s = set_block($s, (lit * cap) + c, i)
    $s = set_count($s, lit, c + 1)
    $s
}

run_seq_var = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_seq_var($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# W4: `?` inside a callee that uses a `var` local — does the var idiom rescue early return?
step_try_var = |st, lit, cap, i| {
    var $s = st
    c = $s.counts.get(lit)?
    $s = { ..$s, blocks: $s.blocks.set((lit * cap) + c, i)? }
    $s = { ..$s, counts: $s.counts.set(lit, c + 1)? }
    Ok($s)
}

run_try_var = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_try_var($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

# W5: pipeline of two write helpers directly (no intermediate binding)
step_pipe = |st, lit, cap, i| {
    c = st.counts.get(lit) ?? 0
    set_count(set_block(st, (lit * cap) + c, i), lit, c + 1)
}

run_pipe = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = step_pipe($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

# X: the real `propagate` shape — a function that RECEIVES the state, runs a
# `var` while-loop over it, and returns it. The whole n-loop is inside the callee.

# Xa: inline reads and writes with `?`
loop_inline = |st, n, m, cap| {
    var $st = st
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit)?
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok($st)
}

run_x_inline = |m, cap, n| {
    st = loop_inline(new_state(m, cap), n, m, cap)?
    Ok(checksum(st))
}

# Xb: read helper + write helper, `??` only
loop_helpers = |st, n, m, cap| {
    var $st = st
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = count_of($st, lit)
        $st = write_at($st, lit, cap, c, $i)
        $i = $i + 1
    }
    $st
}

run_x_helpers = |m, cap, n| {
    st = loop_helpers(new_state(m, cap), n, m, cap)
    Ok(checksum(st))
}

# Xc: `$st = step($st)` with a cross-module step, `??` only, no `?` anywhere
loop_mod = |st, n, m, cap| {
    var $st = st
    var $i = 0.U64
    while $i < n {
        $st = Arena.step($st, $i % m, cap, $i)
        $i = $i + 1
    }
    $st
}

run_x_mod = |m, cap, n| {
    st = loop_mod(new_state(m, cap), n, m, cap)
    Ok(checksum(st))
}

# Xd: two levels: outer receives state, var-loops calling an inner that also
# receives state and var-loops (propagate -> for each watch -> ...)
inner_loop = |st, k, base, m, cap| {
    var $st = st
    var $j = 0.U64
    while $j < k {
        i = base + $j
        lit = i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $j = $j + 1
    }
    $st
}

outer_loop = |st, n, m, cap| {
    var $st = st
    var $i = 0.U64
    while $i < n {
        $st = inner_loop($st, 8, $i, m, cap)
        $i = $i + 8
    }
    $st
}

run_x_two = |m, cap, n| {
    st = outer_loop(new_state(m, cap), n, m, cap)
    Ok(checksum(st))
}

# Y1: x_inline with `??` (no early return anywhere)
loop_inline_qq = |st, n, m, cap| {
    var $st = st
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    $st
}

run_y_qq = |m, cap, n| {
    st = loop_inline_qq(new_state(m, cap), n, m, cap)
    Ok(checksum(st))
}

# Y2: receive the record, destructure into two vars (q3 `split` shape), rebuild at end
loop_split = |{ blocks, counts }, n, m, cap| {
    var $blocks = blocks
    var $counts = counts
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $counts.get(lit) ?? 0
        $blocks = $blocks.set((lit * cap) + c, $i) ?? $blocks
        $counts = $counts.set(lit, c + 1) ?? $counts
        $i = $i + 1
    }
    { blocks: $blocks, counts: $counts }
}

run_y_split = |m, cap, n| {
    st = loop_split(new_state(m, cap), n, m, cap)
    Ok(checksum(st))
}

# Y3: receive the record; the var is seeded by a call on the param, not the param itself
loop_seeded = |st, n, m, cap| {
    var $st = identity(st)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    $st
}

run_y_seeded = |m, cap, n| {
    st = loop_seeded(new_state(m, cap), n, m, cap)
    Ok(checksum(st))
}

# Y4: receive the record; first statement is `$st = step($st)` (a call), then inline mutation
loop_prime = |st, n, m, cap| {
    var $st = st
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        $st = identity($st)
        c = $st.counts.get(lit) ?? 0
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i) ?? $st.blocks }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1) ?? $st.counts }
        $i = $i + 1
    }
    $st
}

run_y_prime = |m, cap, n| {
    st = loop_prime(new_state(m, cap), n, m, cap)
    Ok(checksum(st))
}

# (e) self-recursive loop threading the state
loop_rec = |st, i, n, m, cap| {
    if i >= n {
        st
    } else {
        loop_rec(step(st, i % m, cap, i), i + 1, n, m, cap)
    }
}

run_rec = |m, cap, n| {
    st = loop_rec(new_state(m, cap), 0.U64, n, m, cap)
    Ok(checksum(st))
}

# ---------------------------------------------------------------- cross module (void module, plain record)

run_mod = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = Arena.step($st, $i % m, cap, $i)
        $i = $i + 1
    }
    Ok(checksum($st))
}

run_mod_try = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = Arena.step_try($st, $i % m, cap, $i)?
        $i = $i + 1
    }
    Ok(checksum($st))
}

run_mod_tuple = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    var $acc = 0.U64
    while $i < n {
        (st2, c) = Arena.step_tuple($st, $i % m, cap, $i)
        $st = st2
        $acc = $acc + c
        $i = $i + 1
    }
    Ok(checksum($st) + $acc)
}

run_mod_read = |m, cap, n| {
    var $st = new_state(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = Arena.count_of($st, lit)
        $st = { ..$st, blocks: $st.blocks.set((lit * cap) + c, $i)? }
        $st = { ..$st, counts: $st.counts.set(lit, c + 1)? }
        $i = $i + 1
    }
    Ok(checksum($st))
}

run_mod_rec = |m, cap, n| {
    st = Arena.run(new_state(m, cap), 0.U64, n, m, cap)
    Ok(checksum(st))
}

# ---------------------------------------------------------------- cross module (nominal type + methods)

run_nom = |m, cap, n| {
    var $st = Sol.new(m, cap)
    var $i = 0.U64
    while $i < n {
        $st = $st.step($i % m, cap, $i)
        $i = $i + 1
    }
    Ok($st.checksum())
}

run_nom_read = |m, cap, n| {
    var $st = Sol.new(m, cap)
    var $i = 0.U64
    while $i < n {
        lit = $i % m
        c = $st.count_of(lit)
        $st = $st.write(lit, cap, c, $i)
        $i = $i + 1
    }
    Ok($st.checksum())
}

run_nom_rec = |m, cap, n| {
    st = Sol.run(Sol.new(m, cap), 0.U64, n, m, cap)
    Ok(st.checksum())
}
