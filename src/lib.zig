//! lib.zig — barrel module that re-exports zephem's internals under one name, so tests under
//! src/test/ can `@import("zephem")` and reach any module (a test file can't `@import("../x.zig")`
//! across the module boundary; a named module import is the sanctioned way in).
//!
//! Only the leaf modules that need no engine (`parse`/`derive`) imports are re-exported here — the
//! subset the current tests exercise. Add more as tests grow (a module that imports `parse`/`derive`
//! also needs those wired into the test module in build.zig).
pub const util = @import("util.zig");
pub const relation = @import("relation.zig");
pub const manifest = @import("manifest.zig");
pub const proc = @import("proc.zig");
pub const vars = @import("vars.zig");
pub const toolchain = @import("toolchain.zig");
pub const ctx = @import("ctx.zig");
pub const sig = @import("sig.zig");
pub const query = @import("query.zig");
