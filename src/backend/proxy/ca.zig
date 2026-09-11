//! Private local certificate authority used only by Telar child processes.

const ResourcesType = @import("Resources.zig");
const AuthorityFilesType = @import("AuthorityFiles.zig");
const PairType = @import("Pair.zig");
const AuthorityType = @import("Authority.zig");
const std = @import("std");
const tlsz = @import("tls");
const SecureWrite = @import("SecureWrite.zig");

pub const Error = error{
    KeygenFailed,
    CertFailed,
    WriteFailed,
    ReadFailed,
    IncompleteAuthority,
};

pub const ca_seconds: i64 = 3650 * 24 * 60 * 60;
pub const system_ca_seconds: i64 = 30 * 24 * 60 * 60;
pub const leaf_seconds: i64 = 30 * 24 * 60 * 60;
pub const backdate_seconds: i64 = 3600;
pub const max_cert_len = 1024;
pub const max_pem_len = 2 * max_cert_len;
pub const ca_common_name = "telar local CA";

pub const Resources = @import("Resources.zig");

pub const AuthorityFiles = @import("AuthorityFiles.zig");

pub const Pair = @import("Pair.zig");

pub const Authority = @import("Authority.zig");

pub fn generate(io: std.Io, validity_seconds: i64) Error!PairType {
    const now = std.Io.Clock.real.now(io).toSeconds();
    var pair: PairType = .{ .key_pair = tlsz.x509.KeyPair.generate(io) };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    const cert = tlsz.x509.create(
        &pair.cert_buf,
        .{
            .common_name = ca_common_name,
            .serial = randomSerial(io),
            .not_before = now - backdate_seconds,
            .not_after = now + validity_seconds,
            .is_ca = true,
        },
        pair.key_pair.public_key,
        .{ .common_name = ca_common_name, .key_pair = &pair.key_pair },
    ) catch return error.CertFailed;
    pair.cert_len = cert.len;
    return pair;
}

pub fn load(resources: ResourcesType, files: AuthorityFilesType) Error!PairType {
    const io = resources.io;
    const gpa = resources.allocator;

    const key_pem = std.Io.Dir.cwd().readFileAlloc(io, files.key, gpa, .limited(max_pem_len)) catch
        return error.ReadFailed;
    defer {
        std.crypto.secureZero(u8, key_pem);
        gpa.free(key_pem);
    }
    const cert_pem = std.Io.Dir.cwd().readFileAlloc(io, files.certificate, gpa, .limited(max_pem_len)) catch
        return error.ReadFailed;
    defer gpa.free(cert_pem);

    const parsed = tlsz.config.PrivateKey.parsePem(key_pem) catch return error.ReadFailed;
    if (parsed.signature_scheme != .ecdsa_secp256r1_sha256) {
        return error.ReadFailed;
    }
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    var secret = Ecdsa.SecretKey.fromBytes(
        parsed.key.ecdsa[0..Ecdsa.SecretKey.encoded_length].*,
    ) catch return error.ReadFailed;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&secret));
    var pair: PairType = .{
        .key_pair = tlsz.x509.KeyPair.fromSecretKey(secret) catch return error.ReadFailed,
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    const der = tlsz.x509.decodePem(&pair.cert_buf, cert_pem) catch return error.ReadFailed;
    pair.cert_len = der.len;
    const parsed_cert = (std.crypto.Certificate{
        .buffer = pair.certDer(),
        .index = 0,
    }).parse() catch return error.ReadFailed;
    parsed_cert.verify(parsed_cert, std.Io.Clock.real.now(io).toSeconds()) catch
        return error.ReadFailed;
    const authority: AuthorityType = .{ .pair = pair };
    var probe = authority.mint(io, "validation.telar.invalid") catch
        return error.ReadFailed;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&probe));
    const parsed_probe = (std.crypto.Certificate{
        .buffer = probe.certDer(),
        .index = 0,
    }).parse() catch return error.ReadFailed;
    parsed_probe.verify(parsed_cert, std.Io.Clock.real.now(io).toSeconds()) catch
        return error.ReadFailed;
    return pair;
}

pub fn persist(io: std.Io, pair: *const PairType, files: AuthorityFilesType) Error!void {
    var buffer: [max_pem_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    // Create both destinations with 0600 from their first inode. Exclusive
    // creation refuses to overwrite another runtime's authority.
    try writeSecure(io, .{ .path = files.key, .bytes = try pair.keyPem(&buffer), .exclusive = true });
    writeSecure(io, .{ .path = files.certificate, .bytes = try pair.certPem(&buffer), .exclusive = true }) catch
        return error.IncompleteAuthority;
}

pub fn writeSecure(io: std.Io, write: SecureWrite) Error!void {
    const path = write.path;

    if (!std.fs.path.isAbsolute(path)) {
        return error.WriteFailed;
    }
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (0..8) |_| {
        const temp_path = std.fmt.bufPrint(
            &temp_buffer,
            "{s}.tmp-{x}",
            .{ path, randomSerial(io) },
        ) catch return error.WriteFailed;
        const file = std.Io.Dir.createFileAbsolute(io, temp_path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return error.WriteFailed,
        };
        file.writeStreamingAll(io, write.bytes) catch {
            file.close(io);
            std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
            return error.WriteFailed;
        };
        file.sync(io) catch {
            file.close(io);
            std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
            return error.WriteFailed;
        };
        file.close(io);
        const cwd = std.Io.Dir.cwd();
        if (write.exclusive) {
            std.Io.Dir.renamePreserve(cwd, temp_path, cwd, path, io) catch {
                std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
                return error.WriteFailed;
            };
        } else {
            std.Io.Dir.renameAbsolute(temp_path, path, io) catch {
                std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
                return error.WriteFailed;
            };
        }
        return;
    }
    return error.WriteFailed;
}

pub fn pathExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    return true;
}

pub fn validateStoredFile(io: std.Io, path: []const u8) Error!void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch
        return error.ReadFailed;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        return error.ReadFailed;
    }
}

pub fn readSystemRoots(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    for ([_][]const u8{
        "/etc/ssl/cert.pem",
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
    }) |path| return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch continue;
    return error.FileNotFound;
}

pub fn randomSerial(io: std.Io) u64 {
    const source: std.Random.IoSource = .{ .io = io };
    return source.interface().int(u64) >> 1;
}

test "minted leaves verify against the local authority" {
    const io = std.testing.io;
    const authority: AuthorityType = .{ .pair = try generate(io, ca_seconds) };
    const leaf = try authority.mint(io, "api.anthropic.com");
    const parsed_leaf = try (std.crypto.Certificate{ .buffer = leaf.certDer(), .index = 0 }).parse();
    const parsed_ca = try (std.crypto.Certificate{ .buffer = authority.pair.certDer(), .index = 0 }).parse();
    try parsed_leaf.verify(parsed_ca, std.Io.Clock.real.now(io).toSeconds());
    try parsed_leaf.verifyHostName("api.anthropic.com");
}

test "authority files and derived bundle are owner-only" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);
    const directory = directory_buffer[0..directory_len];
    var key_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var cert_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var bundle_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const key_path = try std.fmt.bufPrint(&key_buffer, "{s}/ca-key.pem", .{directory});
    const cert_path = try std.fmt.bufPrint(&cert_buffer, "{s}/ca-cert.pem", .{directory});
    const bundle_path = try std.fmt.bufPrint(&bundle_buffer, "{s}/ca-bundle.pem", .{directory});

    const resources: ResourcesType = .{ .io = io, .allocator = gpa };
    const files: AuthorityFilesType = .{ .key = key_path, .certificate = cert_path };
    var authority = try AuthorityType.loadOrCreate(resources, files);
    try authority.writeBundle(resources, bundle_path);
    _ = try AuthorityType.loadOrCreate(resources, files);
    for ([_][]const u8{ key_path, cert_path, bundle_path }) |path| {
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(std.Io.File.Kind.file, stat.kind);
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "system authorities have a bounded 30-day lifetime" {
    const io = std.testing.io;
    const authority: AuthorityType = .{ .pair = try generate(io, system_ca_seconds) };
    try std.testing.expect(try authority.hasSystemLifetime());
    try std.testing.expect(!(try (AuthorityType{ .pair = try generate(io, ca_seconds) }).hasSystemLifetime()));
    try std.testing.expectEqual(@as(usize, 40), authority.fingerprint().len);
}
