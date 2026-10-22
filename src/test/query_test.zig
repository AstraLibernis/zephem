// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const testing = std.testing;
const query = @import("zephem").query;

test "std.c and std.os paths are demoted; everything else is not" {
    try testing.expect(query.platformDemoted("std.os.linux.mmap", &.{"mmap"}));
    try testing.expect(query.platformDemoted("std.c.darwin.mach_task_self", &.{"task"}));
    try testing.expect(query.platformDemoted("std.c.COPYFILE", &.{"copy"}));
    try testing.expect(!query.platformDemoted("std.Io.Dir.copyFile", &.{"copy"}));
    try testing.expect(!query.platformDemoted("std.crypto.aes", &.{"aes"})); // `std.c` prefix is not `std.crypto`
    try testing.expect(!query.platformDemoted("std.compress", &.{}));
}

test "a term equal to the platform segment opts back in; a substring does not" {
    try testing.expect(!query.platformDemoted("std.os.linux.mmap", &.{ "linux", "mmap" }));
    try testing.expect(!query.platformDemoted("std.c.darwin.mach_task_self", &.{"darwin"}));
    try testing.expect(!query.platformDemoted("std.os.linux", &.{"linux"}));
    try testing.expect(query.platformDemoted("std.os.linux.mmap", &.{"lin"}));
    // in std.c.COPYFILE the segment is the decl itself — `copy` must not match it, `copyfile` does
    try testing.expect(!query.platformDemoted("std.c.COPYFILE", &.{"copyfile"}));
}

test "an alternative name ranks only if one writable name holds every term" {
    const aka = "std.Io.Threaded.linux_copy_file_range_sys.[then].mmap, std.posix.system.[then].mmap";
    try testing.expect(!query.akaContains(aka, &.{ "linux", "mmap" })); // only through a platform arm
    try testing.expect(query.akaContains("std.ArrayList.append, std.array_list.Aligned().append", &.{ "arraylist", "append" }));
    // terms spread over two names are not one name the caller would write
    try testing.expect(!query.akaContains("std.foo.alpha, std.bar.beta", &.{ "alpha", "beta" }));
    try testing.expect(!query.akaContains("", &.{"x"}));
}
