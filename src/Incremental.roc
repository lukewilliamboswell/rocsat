# Parser for the incremental CLI transcript: `+ literals 0` adds a clause and `? literals 0`
# solves under assumptions. Whitespace and DIMACS `c` comment lines are accepted between commands.

import Scanner

Incremental :: [].{
    Operation : [Add(List(I32)), Solve(List(I32))]
    Error : [UnexpectedByte(U64), VariableTooLarge(U64), MissingTerminator]

    parse : List(U8) -> Try(List(Operation), Error)
    parse = |bytes| {
        n = bytes.len()
        var $i = 0
        var $operations = []
        while $i < n {
            $i = Scanner.skip_comments(bytes, $i)
            if $i < n {
                prefix = bytes.get($i) ?? 0
                if prefix == 'p' {
                    $i = Scanner.skip_line(bytes, $i)
                } else if prefix == '+' or prefix == '?' {
                    (lits, next) = read_literals(bytes, $i + 1)?
                    if prefix == '+' {
                        $operations = $operations.append(Add(lits))
                    } else {
                        $operations = $operations.append(Solve(lits))
                    }
                    $i = next
                } else {
                    return Err(UnexpectedByte($i))
                }
            }
        }
        Ok($operations)
    }

    read_literals : List(U8), U64 -> Try((List(I32), U64), Error)
    read_literals = |bytes, start| {
        var $i = start
        var $lits = []
        while $i < bytes.len() {
            num = read_number(bytes, $i)?
            $i = num.next
            if num.value == 0 {
                return Ok(($lits, $i))
            }
            id = num.value.to_u32_wrap().to_i32_wrap()
            $lits = $lits.append(if num.sign == 0 { id } else { id.negate() })
        }
        Err(MissingTerminator)
    }

    read_number : List(U8), U64 -> Try({ value : U64, sign : U64, next : U64 }, Error)
    read_number = |bytes, start| match Scanner.read_number(bytes, start) {
        Ok(num) => Ok(num)
        Err(UnexpectedByte(at)) => Err(UnexpectedByte(at))
        Err(VariableTooLarge(at)) => Err(VariableTooLarge(at))
    }
}

expect Incremental.parse("p rocsat\n+ 1 -2 0\n? -1 2 0\n".to_utf8()) == Ok([Add([1, -2]), Solve([-1, 2])])
expect Incremental.parse("c hi\n+ 0\n? 0\n".to_utf8()) == Ok([Add([]), Solve([])])
expect Incremental.parse("+ 1".to_utf8()) == Err(MissingTerminator)
expect Incremental.parse("x 0\n".to_utf8()) == Err(UnexpectedByte(0))
