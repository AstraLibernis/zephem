#!/usr/bin/env nu
# zlook.nu — build-if-stale wrapper around query/zlook.zig, then run the binary.
# zlook is the SIMD keyword search over the baked lookup table; an LLM runs it many
# times per session, so we compile ONCE to $ZEPHEM_ZLOOK (default ~/.config/zephem/zlook)
# and rebuild only when the source is newer — every later call is the raw binary
# (single-digit ms). No committed artifact; the binary lives outside the repo, matching
# zephem's "the product is the pipeline, not the bytes" ethos. All args pass through.
#
#   nu query/zlook.nu parse int
#   nu query/zlook.nu OutOfMemory --limit 20
# --limit is declared here (with zlook's own default) only so nu's parser passes it
# through to the binary instead of rejecting it as an unknown flag; all positional
# terms flow through untouched in $args.
def main [...args: string, --limit (-l): int = 12] {
    let src   = ($env.FILE_PWD | path join zlook.zig)
    let bin   = ($env.ZEPHEM_ZLOOK? | default ($env.HOME | path join .config zephem zlook))
    let cache = ($bin | path dirname | path join .zig-cache)
    mkdir ($bin | path dirname)
    let stale = if ($bin | path exists) {
        (ls $src | get 0.modified) > (ls $bin | get 0.modified)
    } else { true }
    if $stale {
        print -e $"zlook: compiling ($src) -> ($bin) ..."
        ^zig build-exe -OReleaseFast --cache-dir $cache $"-femit-bin=($bin)" $src
    }
    ^$bin ...$args --limit ($limit | into string)
}
