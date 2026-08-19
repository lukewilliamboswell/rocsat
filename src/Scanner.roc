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
        var $i = start
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
