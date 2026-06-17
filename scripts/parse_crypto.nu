#!/usr/bin/env nu
# parse_crypto.nu — walk every .zig file under std/crypto, extract every pub
# declaration exactly as written in source, write data/crypto_raw.csv.
# No interpretation, no sorting, no labelling — just what the files say.
#
# Usage:
#   nu scripts/parse_crypto.nu                  # parse + regenerate inventory
#   nu scripts/parse_crypto.nu --skip-inventory # parse only

def main [] {
    let std_root   = "/usr/lib/zig/std"
    let out_csv    = "data/crypto_raw.csv"
    let crypto_dir = $"($std_root)/crypto"
    let top_file   = $"($std_root)/crypto.zig"

    # all .zig files under crypto/ plus the top-level crypto.zig
    let files = (
        (glob $"($crypto_dir)/**/*.zig") ++ [$top_file]
        | sort
    )

    print $"scanning ($files | length) files..."

    let rows = ($files | each {|f|
        let rel         = ($f | str replace $"($std_root)/" "")
        let is_reexport = ($f == $top_file)
        let content     = (open --raw $f)

        # reduce over lines, tracking a doc-comment buffer
        let result = ($content | lines | enumerate | reduce -f {buf: [], rows: []} {|it, acc|
            let ln      = ($it.index + 1)
            let raw     = $it.item
            let trimmed = ($raw | str trim)

            if ($trimmed | str starts-with "///") {
                # accumulate doc comment
                let text = ($trimmed | str replace -r '^//+\s*' '')
                {buf: ($acc.buf | append $text), rows: $acc.rows}

            } else {
                let m = ($trimmed | parse --regex '^pub\s+(?P<kind>const|fn|var|type)\s+(?P<name>\w+)')
                if ($m | is-not-empty) {
                    let kind   = ($m | get kind | first)
                    let name   = ($m | get name | first)
                    let row = {
                        file:        $rel
                        line:        $ln
                        indent:      (($raw | str length) - ($raw | str trim --left | str length))
                        name:        $name
                        kind:        $kind
                        is_import:   ($trimmed | str contains "@import")
                        is_reexport: $is_reexport
                        signature:   ($trimmed | str substring 0..300)
                        doc:         ($acc.buf | str join " | ")
                    }
                    {buf: [], rows: ($acc.rows | append $row)}
                } else if ($trimmed | str length) > 0 and not ($trimmed | str starts-with "//") {
                    # non-comment, non-pub line clears the doc buffer
                    {buf: [], rows: $acc.rows}
                } else {
                    # blank line or comment — preserve buf
                    $acc
                }
            }
        })

        print -n $"\r  ($rel): ($result.rows | length) decls              "
        $result.rows
    } | flatten)

    print $"\n\ntotal declarations: ($rows | length)"

    mkdir data
    $rows | save -f $out_csv
    print $"CSV written → ($out_csv)"
}
