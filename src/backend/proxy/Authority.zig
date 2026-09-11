const Pair = @import("Pair.zig");
const Resources = @import("Resources.zig");
const AuthorityFiles = @import("AuthorityFiles.zig");
const ca = @import("ca.zig");
const std = @import("std");
const tls = @import("tls");
const Authority = @This();

pair: Pair,

/// Loads one complete authority or atomically creates both missing files.
/// A partial key/certificate pair is rejected instead of being repaired.
///
/// ```zig
/// var authority = try Authority.loadOrCreate(resources, files);
/// ```
pub fn loadOrCreate(resources: Resources, files: AuthorityFiles) ca.Error!Authority {
    return loadOrCreateWithValidity(resources, files, ca.ca_seconds);
}

/// Loads a complete system-trust authority or creates a new 30-day one.
/// The caller owns installation in the platform trust store.
///
/// ```zig
/// var authority = try Authority.loadOrCreateSystem(resources, files);
/// ```
pub fn loadOrCreateSystem(resources: Resources, files: AuthorityFiles) ca.Error!Authority {
    return loadOrCreateWithValidity(resources, files, ca.system_ca_seconds);
}

/// Loads an existing authority without creating missing files.
///
/// ```zig
/// const authority = try Authority.loadExisting(resources, files);
/// ```
pub fn loadExisting(resources: Resources, files: AuthorityFiles) ca.Error!Authority {
    try ca.validateStoredFile(resources.io, files.key);
    try ca.validateStoredFile(resources.io, files.certificate);

    return .{ .pair = try ca.load(resources, files) };
}

/// Creates a new 30-day authority at unused paths. This is the rotation
/// primitive; it never overwrites the currently installed authority.
///
/// ```zig
/// var authority = try Authority.createSystem(resources, temporary_files);
/// ```
pub fn createSystem(resources: Resources, files: AuthorityFiles) ca.Error!Authority {
    var pair = try ca.generate(resources.io, ca.system_ca_seconds);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    try ca.persist(resources.io, &pair, files);
    return .{ .pair = pair };
}

/// Returns the uppercase SHA-1 certificate fingerprint accepted by the
/// macOS `security -Z` option.
///
/// ```zig
/// const fingerprint = authority.fingerprint();
/// ```
pub fn fingerprint(authority: *const Authority) [40]u8 {
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(authority.pair.certDer(), &digest, .{});
    return std.fmt.bytesToHex(digest, .upper);
}

/// Reports whether the certificate expires within `seconds` from now.
///
/// ```zig
/// if (authority.expiresWithin(io, 86400)) rotate();
/// ```
pub fn expiresWithin(authority: *const Authority, io: std.Io, seconds: u64) ca.Error!bool {
    const parsed = (std.crypto.Certificate{ .buffer = authority.pair.certDer(), .index = 0 }).parse() catch
        return error.ReadFailed;
    const now: u64 = @intCast(@max(std.Io.Clock.real.now(io).toSeconds(), 0));
    return parsed.validity.not_after <= now +| seconds;
}

/// Reports whether the certificate has Telar's bounded system-trust
/// lifetime rather than the ten-year private-CA lifetime.
///
/// ```zig
/// if (!try authority.hasSystemLifetime()) rejectAuthority();
/// ```
pub fn hasSystemLifetime(authority: *const Authority) ca.Error!bool {
    const parsed = (std.crypto.Certificate{ .buffer = authority.pair.certDer(), .index = 0 }).parse() catch
        return error.ReadFailed;
    const lifetime = parsed.validity.not_after -| parsed.validity.not_before;
    return lifetime <= ca.system_ca_seconds + ca.backdate_seconds;
}

fn loadOrCreateWithValidity(resources: Resources, files: AuthorityFiles, validity_seconds: i64) ca.Error!Authority {
    const io = resources.io;
    const key_path = files.key;
    const cert_path = files.certificate;

    const key_exists = ca.pathExists(io, key_path) catch return error.ReadFailed;
    const cert_exists = ca.pathExists(io, cert_path) catch return error.ReadFailed;
    if (key_exists != cert_exists) {
        return error.IncompleteAuthority;
    }
    if (key_exists) {
        try ca.validateStoredFile(io, key_path);
        try ca.validateStoredFile(io, cert_path);
        const authority: Authority = .{ .pair = try ca.load(resources, files) };
        if (validity_seconds == ca.system_ca_seconds and !(try authority.hasSystemLifetime())) {
            return error.ReadFailed;
        }

        return authority;
    }

    var pair = try ca.generate(io, validity_seconds);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    try ca.persist(io, &pair, files);
    return .{ .pair = pair };
}

/// `SSL_CERT_FILE` replaces system trust. The child therefore receives a
/// bundle containing both platform roots and Telar's private authority.
///
/// ```zig
/// try authority.writeBundle(resources, output_path);
/// ```
pub fn writeBundle(authority: *const Authority, resources: Resources, output_path: []const u8) ca.Error!void {
    const io = resources.io;
    const gpa = resources.allocator;

    const roots = ca.readSystemRoots(io, gpa) catch return error.ReadFailed;
    defer gpa.free(roots);
    var pem_buffer: [ca.max_pem_len]u8 = undefined;
    const ours = try authority.pair.certPem(&pem_buffer);
    const bundle = std.mem.concat(gpa, u8, &.{ roots, ours }) catch return error.WriteFailed;
    defer gpa.free(bundle);
    try ca.writeSecure(io, .{ .path = output_path, .bytes = bundle, .exclusive = false });
}

pub fn mint(authority: *const Authority, io: std.Io, host: []const u8) ca.Error!Pair {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var leaf: Pair = .{ .key_pair = tls.x509.KeyPair.generate(io) };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&leaf));
    const cert = tls.x509.create(
        &leaf.cert_buf,
        .{
            .common_name = host,
            .dns_name = host,
            .serial = ca.randomSerial(io),
            .not_before = now - ca.backdate_seconds,
            .not_after = now + ca.leaf_seconds,
        },
        leaf.key_pair.public_key,
        .{ .common_name = ca.ca_common_name, .key_pair = &authority.pair.key_pair },
    ) catch return error.CertFailed;
    leaf.cert_len = cert.len;
    return leaf;
}
