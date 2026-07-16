//! build.zig — zephem builds by Zig. One `zephem` binary with subcommands; each named step
//! below invokes it with the matching subcommand. `reflect/resolve.zig` is NOT built here —
//! it is a compile-per-container template the `depth` subcommand rewrites and `zig run`s.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The three engines live in their own directories (parse/ · reflect/ · derive/); the ex-Nushell
    // orchestration, relational lib, overlays, query, and docs live in src/. The parser and index
    // engines are imported as modules so `zephem std` drives them in-process. (reflect/resolve.zig
    // is NOT built here — it is a compile-per-container template the `depth` subcommand `zig run`s.)
    const parse_mod = b.createModule(.{ .root_source_file = b.path("parse/build.zig"), .target = target, .optimize = optimize });
    const derive_mod = b.createModule(.{ .root_source_file = b.path("derive/index.zig"), .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "zephem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parse", .module = parse_mod },
                .{ .name = "derive", .module = derive_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // A subcommand step: `zig build <name>` runs the installed binary with `sub` (plus any
    // trailing `-- <args>` the user passes through).
    const Sub = struct {
        fn add(bb: *std.Build, e: *std.Build.Step.Compile, name: []const u8, desc: []const u8, argv: []const []const u8) void {
            const run = bb.addRunArtifact(e);
            run.addArgs(argv);
            if (bb.args) |ua| run.addArgs(ua);
            bb.step(name, desc).dependOn(&run.step);
        }
    };
    Sub.add(b, exe, "std", "regenerate the core std map (parse+index+verify+manifest)", &.{"std"});
    Sub.add(b, exe, "depth", "run the L5 reflection sweep (slow; --commit/--only/--jobs …)", &.{"depth"});
    Sub.add(b, exe, "overlays", "rebuild the derived overlays (canon,consensus,callcard,doccov,sigshape)", &.{"overlays"});
    Sub.add(b, exe, "docs", "regenerate the markdown docs from templates/", &.{"docs"});
    Sub.add(b, exe, "lookup", "bake the denormalized lookup table zlook searches", &.{"lookup"});
    Sub.add(b, exe, "smoke", "run the query smoke battery", &.{"test"});

    // `zig build check` — the FAST parity gate: map + overlays + docs each prove they rebuild.
    // Deliberately excludes the depth sweep (two full reflection passes — machine-dependent).
    const check = b.step("check", "fast parity gate: std --check && overlays --check && docs --check");
    inline for (.{ "std", "overlays", "docs" }) |sub| {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ sub, "--check" });
        check.dependOn(&run.step);
    }
    {
        const run = b.addRunArtifact(exe);
        run.addArgs(&.{ "depth", "--check" });
        b.step("depth-check", "prove the depth overlay rebuilds (SLOW, machine-dependent)").dependOn(&run.step);
    }

    // `zig build test` — unit tests under src/test/. They reach the internals via the `zephem`
    // barrel module (a test file can't import across the module boundary directly).
    const zephem_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "run unit tests");
    inline for (.{
        "src/test/relation_test.zig",
        "src/test/manifest_test.zig",
    }) |tf| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(tf),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zephem", .module = zephem_mod }},
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
