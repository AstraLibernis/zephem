//! surface.zig — classify the PUBLIC surface of std.crypto by reflection.
//!
//! Walks the crypto namespace tree and labels every public declaration so we can
//! answer, authoritatively (not by hand-curation): what does a developer actually
//! type? Three classes matter here:
//!   PRIMITIVE — an instantiable type you reach for (Sha256, ChaCha20Poly1305, Box)
//!   BUILDER   — a generic `fn(...) type` the primitives are aliases of (Sha2x32,
//!               AesGcm, ChaChaPoly) — you address it through its named alias
//!   free-fn   — a callable operation that isn't a method (pbkdf2, timingSafeEql)
//! plus `namespace` (organizational) and `const`/`alias` (values, error sets).
//!
//! The math/hardware/protocol machinery (curve field ops, AES CPU backends, TLS,
//! X.509) is deliberately NOT walked here — it isn't part of the surface you type.
//! It's labelled separately, by file, from the text inventory. See docs/layers.md.
//!
//! Output: TSV  path <TAB> name <TAB> class
//! Run: zig run src/surface.zig

const std = @import("std");
const crypto = std.crypto;

// Namespaces we do NOT descend into: the math/hardware/protocol layer. Naming
// these explicitly keeps the walk to the user-facing surface.
const skip = [_][]const u8{
    // math / hardware / protocol trees — not part of the typed surface
    "pcurves", "ecc",  "ff",     "field", "scalar", "core",  "tls",
    "codecs",  "Certificate", "benchmark", "kyber_d00", "Curve", "key_blinding",
    "phc_format", "BatchElement",
    // per-primitive config structs — addressed as a primitive's option, not reached for
    "Params", "Mode", "Options", "KdfOptions", "HashOptions", "VerifyOptions",
};

fn skipped(comptime name: []const u8) bool {
    inline for (skip) |s| if (comptime std.mem.eql(u8, name, s)) return true;
    return false;
}

fn hasMarker(comptime T: type) bool {
    inline for (.{
        // symmetric / hash / mac / kdf surface
        "digest_length", "key_length", "nonce_length", "tag_length", "mac_length",
        "secret_length", "shared_length", "seed_length", "noise_length",
        "encrypt",       "hash",       "sign",        "create",      "seal", "extract",
        // signature / KEM schemes carry their API on these nested types
        "KeyPair",       "PublicKey",  "Signature",   "EncapsulatedSecret",
    }) |m| {
        if (@hasDecl(T, m)) return true;
    }
    return false;
}

fn classOf(comptime val: anytype) []const u8 {
    const VT = @TypeOf(val);
    if (VT == type) {
        return switch (@typeInfo(val)) {
            .@"struct", .@"enum", .@"union" => if (comptime hasMarker(val)) "PRIMITIVE" else "namespace",
            else => "alias",
        };
    }
    return switch (@typeInfo(VT)) {
        .@"fn" => |f| if (f.return_type == type) "BUILDER" else "free-fn",
        else => "const",
    };
}

fn walk(w: anytype, comptime path: []const u8, comptime NS: type, comptime depth: u8) !void {
    const info = @typeInfo(NS);
    if (info != .@"struct") return;
    inline for (info.@"struct".decls) |d| {
        if (comptime skipped(d.name)) continue;
        const val = @field(NS, d.name);
        const class = comptime classOf(val);
        try w.print("{s}\t{s}\t{s}\n", .{ path, d.name, class });
        // descend only into organizational namespaces, never into primitives
        if (comptime std.mem.eql(u8, class, "namespace") and depth > 0) {
            try walk(w, path ++ "." ++ d.name, val, depth - 1);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var wbuf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &wbuf);
    const w = &fw.interface;
    try w.print("path\tname\tclass\n", .{});
    inline for (.{
        .{ "hash", crypto.hash },
        .{ "auth", crypto.auth },
        .{ "onetimeauth", crypto.onetimeauth },
        .{ "aead", crypto.aead },
        .{ "stream", crypto.stream },
        .{ "kdf", crypto.kdf },
        .{ "pwhash", crypto.pwhash },
        .{ "sign", crypto.sign },
        .{ "dh", crypto.dh },
        .{ "kem", crypto.kem },
        .{ "nacl", crypto.nacl },
    }) |entry| {
        try walk(w, entry[0], entry[1], 3);
    }
    try w.flush();
}
