inner = |x| {
    expect x > 100      # inline, false for small x
    x + 1
}
expect inner(1) == 2    # top-level: passes even though the inline expect fails?
expect inner(1) == 3    # top-level: fails
main! = |_args| {
    echo!("${inner(1).to_str()}\n")
    Ok({})
}
