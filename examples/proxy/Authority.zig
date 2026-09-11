const Pair = @import("Pair.zig");
const Resources = @import("Resources.zig");
const AuthorityFiles = @import("AuthorityFiles.zig");
const ca = @import("ca.zig");
const std = @import("std");
const tls = @import("tls");
const Authority = @This();

pair: Pair,

/// Loads the CA from `key_path`/`cert_path`, generating and persisting one
/// on first run.
pub fn loadOrCreate(resources: Resources, files: AuthorityFiles) ca.Error!Authority {
    if (ca.load(resources, files)) |pair| {
        return .{ .pair = pair };
    } else |_| {}

    const pair = try ca.generate(resources.io);
    try ca.persist(resources.io, pair, files);
    return .{ .pair = pair };
}

/// Writes the system roots followed by our CA into one PEM bundle.
///
/// Pointing a child at our CA *alone* is the trap: `SSL_CERT_FILE` replaces
/// the trust store rather than extending it, so every connection that does
/// not go through the proxy — and every tool that talks to something else —
/// starts failing with "unable to get issuer cert". The child must trust the
/// real world plus us.
pub fn writeBundle(self: *const Authority, resources: Resources, out_path: []const u8) ca.Error!void {
    const io = resources.io;
    const gpa = resources.allocator;
    const cwd: std.Io.Dir = .cwd();

    const roots = ca.readSystemRoots(io, gpa) catch &[_]u8{};
    defer if (roots.len > 0) gpa.free(roots);

    var pem_buf: [ca.max_pem_len]u8 = undefined;
    const ours = try self.pair.certPem(&pem_buf);

    const bundle = std.mem.concat(gpa, u8, &.{ roots, ours }) catch return error.WriteFailed;
    defer gpa.free(bundle);

    cwd.writeFile(io, .{ .sub_path = out_path, .data = bundle }) catch return error.WriteFailed;
}

/// Mints a leaf certificate for `host`, signed by this authority.
pub fn mint(self: *const Authority, io: std.Io, host: []const u8) ca.Error!Pair {
    const now = std.Io.Clock.real.now(io).toSeconds();

    var leaf: Pair = .{ .key_pair = tls.x509.KeyPair.generate(io) };
    const written = tls.x509.create(
        &leaf.cert_buf,
        .{
            .common_name = host,
            .dns_name = host,
            // Must differ per certificate, or clients cache-collide them.
            .serial = ca.randomSerial(io),
            .not_before = now - ca.backdate_seconds,
            .not_after = now + ca.leaf_seconds,
        },
        leaf.key_pair.public_key,
        .{ .common_name = ca.ca_common_name, .key_pair = &self.pair.key_pair },
    ) catch return error.CertFailed;

    leaf.cert_len = written.len;
    return leaf;
}
