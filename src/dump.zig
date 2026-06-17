//! dump.zig — reflection-based extractor for std.crypto (Zig 0.16).
//!
//! Text parsing of std/crypto can only see declaration lines; it cannot follow
//! aliases or generics (e.g. `ChaCha20Poly1305 = ChaChaPoly(...)`). This program
//! asks the *compiler* instead: for a curated list of primitives we actually
//! instantiate, it reflects over each type's public decls and emits the resolved
//! truth — constant VALUES (key/nonce/tag/digest sizes) and fully-typed function
//! signatures, including error sets.
//!
//! Output: TSV to stdout, one row per declaration:
//!   family <TAB> primitive <TAB> decl <TAB> kind <TAB> detail
//! where detail = integer value (const_int), resolved signature (fn),
//! or type name (type / const_other). Slots straight into the duckdb pipeline.
//!
//! Run: zig run src/dump.zig > data/primitives.tsv

const std = @import("std");
const crypto = std.crypto;

const Entry = struct {
    family: []const u8,
    name: []const u8,
    T: type,
};

/// The primitives a user actually reaches for, grouped by family. This is the
/// curated "use" set — not every symbol, but every symbol you instantiate.
const primitives = [_]Entry{
    // Hashing (c.hash.*)
    .{ .family = "hash", .name = "Blake3", .T = crypto.hash.Blake3 },
    .{ .family = "hash", .name = "Sha256", .T = crypto.hash.sha2.Sha256 },
    .{ .family = "hash", .name = "Sha384", .T = crypto.hash.sha2.Sha384 },
    .{ .family = "hash", .name = "Sha512", .T = crypto.hash.sha2.Sha512 },
    .{ .family = "hash", .name = "Sha3_256", .T = crypto.hash.sha3.Sha3_256 },
    .{ .family = "hash", .name = "Sha3_512", .T = crypto.hash.sha3.Sha3_512 },
    .{ .family = "hash", .name = "Shake128", .T = crypto.hash.sha3.Shake128 },
    .{ .family = "hash", .name = "Shake256", .T = crypto.hash.sha3.Shake256 },
    .{ .family = "hash", .name = "Blake2b256", .T = crypto.hash.blake2.Blake2b256 },
    .{ .family = "hash", .name = "Blake2s256", .T = crypto.hash.blake2.Blake2s256 },
    .{ .family = "hash", .name = "AsconHash256", .T = crypto.hash.ascon.AsconHash256 },
    .{ .family = "hash", .name = "Md5", .T = crypto.hash.Md5 },
    .{ .family = "hash", .name = "Sha1", .T = crypto.hash.Sha1 },
    // MACs
    .{ .family = "mac", .name = "Poly1305", .T = crypto.onetimeauth.Poly1305 },
    .{ .family = "mac", .name = "Ghash", .T = crypto.onetimeauth.Ghash },
    .{ .family = "mac", .name = "HmacSha256", .T = crypto.auth.hmac.sha2.HmacSha256 },
    .{ .family = "mac", .name = "HmacSha512", .T = crypto.auth.hmac.sha2.HmacSha512 },
    // AEAD
    .{ .family = "aead", .name = "ChaCha20Poly1305", .T = crypto.aead.chacha_poly.ChaCha20Poly1305 },
    .{ .family = "aead", .name = "XChaCha20Poly1305", .T = crypto.aead.chacha_poly.XChaCha20Poly1305 },
    .{ .family = "aead", .name = "Aes128Gcm", .T = crypto.aead.aes_gcm.Aes128Gcm },
    .{ .family = "aead", .name = "Aes256Gcm", .T = crypto.aead.aes_gcm.Aes256Gcm },
    .{ .family = "aead", .name = "Aes256GcmSiv", .T = crypto.aead.aes_gcm_siv.Aes256GcmSiv },
    .{ .family = "aead", .name = "Aegis128L", .T = crypto.aead.aegis.Aegis128L },
    .{ .family = "aead", .name = "Aegis256", .T = crypto.aead.aegis.Aegis256 },
    .{ .family = "aead", .name = "AsconAead128", .T = crypto.aead.ascon.AsconAead128 },
    .{ .family = "aead", .name = "IsapA128A", .T = crypto.aead.isap.IsapA128A },
    // Stream ciphers (raw — no auth)
    .{ .family = "stream", .name = "ChaCha20IETF", .T = crypto.stream.chacha.ChaCha20IETF },
    .{ .family = "stream", .name = "XChaCha20IETF", .T = crypto.stream.chacha.XChaCha20IETF },
    .{ .family = "stream", .name = "Salsa20", .T = crypto.stream.salsa.Salsa20 },
    // Key derivation
    .{ .family = "kdf", .name = "HkdfSha256", .T = crypto.kdf.hkdf.HkdfSha256 },
    .{ .family = "kdf", .name = "HkdfSha512", .T = crypto.kdf.hkdf.HkdfSha512 },
    // Key exchange / KEM
    .{ .family = "kex", .name = "X25519", .T = crypto.dh.X25519 },
    .{ .family = "kem", .name = "MlKem768X25519", .T = crypto.kem.hybrid.MlKem768X25519 },
    .{ .family = "kem", .name = "MLKem768", .T = crypto.kem.ml_kem.MLKem768 },
    // Signatures
    .{ .family = "sign", .name = "Ed25519", .T = crypto.sign.Ed25519 },
    .{ .family = "sign", .name = "EcdsaP256Sha256", .T = crypto.sign.ecdsa.EcdsaP256Sha256 },
    .{ .family = "sign", .name = "MLDSA65", .T = crypto.sign.mldsa.MLDSA65 },
    // Password hashing (namespaces of functions, not instantiable types)
    .{ .family = "pwhash", .name = "argon2", .T = crypto.pwhash.argon2 },
    .{ .family = "pwhash", .name = "scrypt", .T = crypto.pwhash.scrypt },
    .{ .family = "pwhash", .name = "bcrypt", .T = crypto.pwhash.bcrypt },
    // Elliptic curves (math layer — investigate last)
    .{ .family = "curve", .name = "Curve25519", .T = crypto.ecc.Curve25519 },
    .{ .family = "curve", .name = "Edwards25519", .T = crypto.ecc.Edwards25519 },
    .{ .family = "curve", .name = "Ristretto255", .T = crypto.ecc.Ristretto255 },
    .{ .family = "curve", .name = "P256", .T = crypto.ecc.P256 },
    .{ .family = "curve", .name = "Secp256k1", .T = crypto.ecc.Secp256k1 },
};

/// Nested types worth recursing into — the usage surface of signatures/KEMs.
/// Everything else (Curve, Fe, field math) is internals we deliberately skip.
const recurse_into = [_][]const u8{
    "KeyPair", "PublicKey", "SecretKey", "Signature", "Signer", "Verifier",
};

fn shouldRecurse(comptime name: []const u8) bool {
    inline for (recurse_into) |w| {
        if (comptime std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

fn classify(comptime field_T: type) []const u8 {
    if (field_T == type) return "type";
    return switch (@typeInfo(field_T)) {
        .@"fn" => "fn",
        .int, .comptime_int => "const_int",
        else => "const_other",
    };
}

fn emitDecls(w: anytype, family: []const u8, comptime prim: []const u8, comptime T: type, comptime depth: u8) !void {
    const info = @typeInfo(T);
    if (info != .@"struct" and info != .@"enum" and info != .@"union") return;
    const decls = switch (info) {
        .@"struct" => |s| s.decls,
        .@"enum" => |e| e.decls,
        .@"union" => |u| u.decls,
        else => unreachable,
    };
    inline for (decls) |d| {
        const field = @field(T, d.name);
        const FT = @TypeOf(field);
        const kind = comptime classify(FT);
        if (comptime std.mem.eql(u8, kind, "const_int")) {
            try w.print("{s}\t{s}\t{s}\t{s}\t{d}\n", .{ family, prim, d.name, kind, field });
        } else if (comptime std.mem.eql(u8, kind, "fn")) {
            try w.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ family, prim, d.name, kind, @typeName(FT) });
        } else if (comptime std.mem.eql(u8, kind, "type")) {
            try w.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ family, prim, d.name, kind, @typeName(field) });
            // recurse only into the usage-relevant nested types, not curve internals
            if (depth > 0 and comptime shouldRecurse(d.name)) {
                try emitDecls(w, family, prim ++ "." ++ d.name, field, depth - 1);
            }
        } else {
            try w.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ family, prim, d.name, kind, @typeName(FT) });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var wbuf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &wbuf);
    const w = &fw.interface;

    try w.print("family\tprimitive\tdecl\tkind\tdetail\n", .{});
    inline for (primitives) |p| {
        try emitDecls(w, p.family, p.name, p.T, 1);
    }
    try w.flush();
}
