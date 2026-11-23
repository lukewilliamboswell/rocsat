# Shared byte scanner for DIMACS-family integer text.

Scanner :: [].{
    Error : [UnexpectedByte(U64), VariableTooLarge(U64)]

    # Signed DIMACS literals must fit the positive half of an I32, and their doubled internal
    # encoding must fit a U32.
    max_number : U64
    max_number = 2147483647

    is_space : U8 -> Bool
    is_space = |b| b == ' ' or (b >= 9 and b <= 13)

    skip_comments : List(U8), U64 -> U64
    skip_comments = |bytes, start| {
        n = bytes.len()
        var $i = start
        var $done = Bool.False
        while !$done {
            b = bytes.get($i) ?? 0
            if $i >= n {
                $done = Bool.True
            } else if is_space(b) {
                $i = $i + 1
            } else if b == 'c' {
                $i = skip_line(bytes, $i)
            } else {
                $done = Bool.True
            }
        }
        $i
    }

    skip_line : List(U8), U64 -> U64
    skip_line = |bytes, start| {
        n = bytes.len()
        vector_limit = n.minus_saturated(15)
        newline = U8x16.splat('\n')
        var $i = start
        while $i < vector_limit {
            chunk = U8x16.load(bytes, $i) ?? crash "line scanner load exceeded its bounds"
            matches = chunk.eq_lanes(newline).to_bitmask()
            if matches != 0 {
                return $i + matches.count_trailing_zero_bits().to_u64()
            }
            $i = $i + 16
        }
        while $i < n and (bytes.get($i) ?? 0) != '\n' {
            $i = $i + 1
        }
        $i
    }

    skip_spaces : List(U8), U64 -> U64
    skip_spaces = |bytes, start| {
        var $i = start
        while is_space(bytes.get($i) ?? 0) {
            $i = $i + 1
        }
        $i
    }

    # Reads one optionally signed decimal token. The sign is 1 for negative and 0 otherwise.
    read_number : List(U8), U64 -> Try({ value : U64, sign : U64, next : U64 }, Error)
    read_number = |bytes, start| {
        n = bytes.len()
        var $i = skip_spaces(bytes, start)
        first = bytes.get($i) ?? 0
        sign = if first == '-' { 1 } else { 0 }
        if first == '-' or first == '+' {
            $i = $i + 1
        }
        digits_start = $i
        var $value = 0
        while $i < n and is_digit(bytes.get($i) ?? 0) {
            $value = $value * 10 + (bytes.get($i) ?? 0).to_u64() - '0'
            if $value > max_number {
                return Err(VariableTooLarge(digits_start))
            }
            $i = $i + 1
        }
        if $i == digits_start or ($i < n and !is_space(bytes.get($i) ?? 0)) {
            return Err(UnexpectedByte($i))
        }
        Ok({ value: $value, sign, next: $i })
    }

    is_digit : U8 -> Bool
    is_digit = |b| b >= '0' and b <= '9'
}

expect Scanner.read_number("  -2147483647 ".to_utf8(), 0) == Ok({ value: 2147483647, sign: 1, next: 13 })
expect Scanner.read_number("+12\n".to_utf8(), 0) == Ok({ value: 12, sign: 0, next: 3 })
expect Scanner.read_number("2147483648".to_utf8(), 0) == Err(VariableTooLarge(0))
expect Scanner.read_number("12x".to_utf8(), 0) == Err(UnexpectedByte(2))

# Cover every vector lane and scalar tail offset from an unaligned start,
# with LF at the end of a CRLF line or with no terminator.
expect {
    var $ok = Bool.True
    for length in (0.U64).until(80) {
        prefix = "abc".to_utf8().concat(List.repeat('x', length))
        bare = prefix.concat("\r".to_utf8())
        terminated = bare.concat("\nremainder".to_utf8())
        $ok = $ok and Scanner.skip_line(terminated, 3) == length + 4
            and Scanner.skip_line(bare, 3) == length + 4
    }
    $ok
}
