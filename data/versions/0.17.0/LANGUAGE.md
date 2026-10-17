<!-- CURATED, not extracted. Hand-written from https://ziglang.org/download/0.17.0/release-notes.html
     on 2026-10-16. The map covers std and builtins; language grammar and semantics it cannot see
     are listed here so a diff against 0.16.0 is complete. Keep each line a fact with its source. -->

Language (0.16.0 → 0.17.0), from the release notes:

- Array/string repetition `x ** n` is removed; use `@splat` for a repeated element
  (`var a: [N]T = @splat(v);`). Repeating a multi-byte string needs a comptime loop.
- `@bitCast` to or from an `extern struct` is no longer allowed; go through a pointer cast.
- `void{}` is removed (write `{}`); `errdefer |err|` captures are removed; the `i0` type is removed.
- `@hasDecl` returns true only for public declarations.
- `std.builtin` moved to `std.lang` (the old name is a deprecated alias until after 0.18.0);
  `OptimizeMode` tags are `debug · safe · fast · small`, and `==`/`!=` against the old tag names
  no longer compile.
- `@import("builtin")` fields `cpu`, `os`, `abi`, `object_format` are deprecated: use
  `target.cpu` / `target.os` / `target.abi` / `target.ofmt`.

Build system (`std.Build`), from the release notes — the parts a build.zig trips on:

- `zig build` runs build.zig in a separate configurer process; the maker runs the graph.
  Build scripts no longer see the install prefix or passthru args at configure time:
  `b.args` → `run.addPassthruArgs()`; `b.getInstallPath(...)` is gone — express install
  paths as a LazyPath with `.relative = .{ .base = .install_prefix | .install_bin | … }`;
  `b.pathFromRoot(x)` is gone — `b.root.joinString(allocator, x)` (b.root is a Cache.Path).
- `addArtifactArg` / `addFileArg` / `addDirectoryArg` / `addOutputFileArg` and their `Prefixed`
  variants are superseded by the `…Arg2(path, .{ .prefix, .suffix, .make_absolute })` forms.
- `std.Build.dependencyLazy` returns `error.LazyDependencyNeeded`; `findProgram` poisons the
  configuration cache (`findProgramLazy` does not).
