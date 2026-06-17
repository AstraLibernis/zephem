#!/usr/bin/env nu
# build_primitives.nu — run the reflection dumper (src/dump.zig), clean the
# resolved type names for human reading, write data/primitives.tsv.
#
# Query it natively, e.g.:
#   open data/primitives.tsv | where kind == 'const_int'
#   open data/primitives.tsv | where primitive == 'ChaCha20Poly1305'
#   open data/primitives.tsv | where family == 'aead' and decl == 'encrypt'

# Strip module-path prefixes and collapse noise so signatures read cleanly.
def clean [] {
    $in
    | str replace -r -a '@typeInfo\(@typeInfo\(@TypeOf\([^()]*\)\)\.@"fn"\.return_type\.\?\)\.error_union\.error_set' 'error{inferred}'
    | str replace -r -a '\.\{[\s\d,]+\}' '…'
    | str replace -r -a 'crypto\.(?:[a-z0-9_]+\.)+' ''
}

def main [] {
    # collect zig's full output before parsing — consuming it as a lazy byte
    # stream races with the external exit-code check and crashes the pipe.
    let raw = (^zig run src/dump.zig | into string)
    # --no-infer keeps every column as text; otherwise const_int values (16, 32…)
    # parse as ints and the string cleanup below fails on them.
    let rows = ($raw | from tsv --no-infer | update detail { $in | clean })
    mkdir data
    $rows | to tsv | save -f data/primitives.tsv
    print $"primitives.tsv written → ($rows | length) rows"
    print ""
    print "sizes that matter (const_int *length), by family:"
    $rows
    | where {|r| $r.kind == 'const_int' and ($r.decl | str ends-with 'length')}
    | select family primitive decl detail
    | sort-by family primitive decl
}
