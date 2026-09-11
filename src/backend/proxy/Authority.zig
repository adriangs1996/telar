const Authority = @This();
const Pair = @import("Pair.zig");
const Resources = @import("Resources.zig");
const AuthorityFiles = @import("AuthorityFiles.zig");
const source_namespace = @import("ca.zig");
const std = @import("std");
pair: Pair,

/// Loads one complete authority or atomically creates both missing files.
/// A partial key/certificate pair is rejected instead of being repaired.
///
/// ```zig
/// var authority = try Authority.loadOrCreate(resources, files);
/// ```
pub fn loadOrCreate(resources: Resources, files: AuthorityFiles) source_namespace.Error!Authority {
    return loadOrCreateWithValidity(resources, files, source_namespace.ca_seconds);
}

/// Loads a complete system-trust authority or creates a new 30-day one.
/// The caller owns installation in the platform trust store.
///
/// ```zig
/// var authority = try Authority.loadOrCreateSystem(resources, files);
/// ```
pub fn loadOrCreateSystem(resources: Resources, files: AuthorityFiles) source_namespace.Error!Authority {
    return loadOrCreateWithValidity(resources, files, source_namespace.system_ca_seconds);
}

/// Loads an existing authority without creating missing files.
///
/// ```zig
/// const authority = try Authority.loadExisting(resources, files);
/// ```
pub fn loadExisting(resources: Resources, files: AuthorityFiles) source_namespace.Error!Authority {
    try source_namespace.validateStoredFile(resources.io, files.key);
    try source_namespace.validateStoredFile(resources.io, files.certificate);

    return .{ .pair = try source_namespace.load(resources, files) };
}

/// Creates a new 30-day authority at unused paths. This is the rotation
/// primitive; it never overwrites the currently installed authority.
///
/// ```zig
/// var authority = try Authority.createSystem(resources, temporary_files);
/// ```
pub fn createSystem(resources: Resources, files: AuthorityFiles) source_namespace.Error!Authority {
    var pair = try source_namespace.generate(resources.io, source_namespace.system_ca_seconds);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    try source_namespace.persist(resources.io, &pair, files);
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
pub fn expiresWithin(authority: *const Authority, io: source_namespace.Io, seconds: u64) source_namespace.Error!bool {
    const parsed = (std.crypto.Certificate{ .buffer = authority.pair.certDer(), .index = 0 }).parse() catch
        return error.ReadFailed;
    const now: u64 = @intCast(@max(source_namespace.Io.Clock.real.now(io).toSeconds(), 0));
    return parsed.validity.not_after <= now +| seconds;
}

/// Reports whether the certificate has Telar's bounded system-trust
/// lifetime rather than the ten-year private-CA lifetime.
///
/// ```zig
/// if (!try authority.hasSystemLifetime()) rejectAuthority();
/// ```
pub fn hasSystemLifetime(authority: *const Authority) source_namespace.Error!bool {
    const parsed = (std.crypto.Certificate{ .buffer = authority.pair.certDer(), .index = 0 }).parse() catch
        return error.ReadFailed;
    const lifetime = parsed.validity.not_after -| parsed.validity.not_before;
    return lifetime <= source_namespace.system_ca_seconds + source_namespace.backdate_seconds;
}

fn loadOrCreateWithValidity(resources: Resources, files: AuthorityFiles, validity_seconds: i64) source_namespace.Error!Authority {
    const io = resources.io;
    const key_path = files.key;
    const cert_path = files.certificate;

    const key_exists = source_namespace.pathExists(io, key_path) catch return error.ReadFailed;
    const cert_exists = source_namespace.pathExists(io, cert_path) catch return error.ReadFailed;
    if (key_exists != cert_exists) {
        return error.IncompleteAuthority;
    }
    if (key_exists) {
        try source_namespace.validateStoredFile(io, key_path);
        try source_namespace.validateStoredFile(io, cert_path);
        const authority: Authority = .{ .pair = try source_namespace.load(resources, files) };
        if (validity_seconds == source_namespace.system_ca_seconds and !(try authority.hasSystemLifetime())) {
            return error.ReadFailed;
        }

        return authority;
    }

    var pair = try source_namespace.generate(io, validity_seconds);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    try source_namespace.persist(io, &pair, files);
    return .{ .pair = pair };
}

/// `SSL_CERT_FILE` replaces system trust. The child therefore receives a
/// bundle containing both platform roots and Telar's private authority.
///
/// ```zig
/// try authority.writeBundle(resources, output_path);
/// ```
pub fn writeBundle(authority: *const Authority, resources: Resources, output_path: []const u8) source_namespace.Error!void {
    const io = resources.io;
    const gpa = resources.allocator;

    const roots = source_namespace.readSystemRoots(io, gpa) catch return error.ReadFailed;
    defer gpa.free(roots);
    var pem_buffer: [source_namespace.max_pem_len]u8 = undefined;
    const ours = try authority.pair.certPem(&pem_buffer);
    const bundle = std.mem.concat(gpa, u8, &.{ roots, ours }) catch return error.WriteFailed;
    defer gpa.free(bundle);
    try source_namespace.writeSecure(io, .{ .path = output_path, .bytes = bundle, .exclusive = false });
}

pub fn mint(authority: *const Authority, io: source_namespace.Io, host: []const u8) source_namespace.Error!Pair {
    const now = source_namespace.Io.Clock.real.now(io).toSeconds();
    var leaf: Pair = .{ .key_pair = source_namespace.x509.KeyPair.generate(io) };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&leaf));
    const cert = source_namespace.x509.create(
        &leaf.cert_buf,
        .{
            .common_name = host,
            .dns_name = host,
            .serial = source_namespace.randomSerial(io),
            .not_before = now - source_namespace.backdate_seconds,
            .not_after = now + source_namespace.leaf_seconds,
        },
        leaf.key_pair.public_key,
        .{ .common_name = source_namespace.ca_common_name, .key_pair = &authority.pair.key_pair },
    ) catch return error.CertFailed;
    leaf.cert_len = cert.len;
    return leaf;
}
