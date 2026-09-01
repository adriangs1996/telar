//! Private local certificate authority used only by Telar child processes.

const std = @import("std");
const tlsz = @import("tls");

const Io = std.Io;
const File = Io.File;
const x509 = tlsz.x509;

pub const Error = error{
    KeygenFailed,
    CertFailed,
    WriteFailed,
    ReadFailed,
    IncompleteAuthority,
};

const ca_seconds: i64 = 3650 * 24 * 60 * 60;
const leaf_seconds: i64 = 30 * 24 * 60 * 60;
const backdate_seconds: i64 = 3600;
const max_cert_len = 1024;
const max_pem_len = 2 * max_cert_len;
const ca_common_name = "telar local CA";

pub const Resources = struct {
    io: Io,
    allocator: std.mem.Allocator,
};

pub const AuthorityFiles = struct {
    key: []const u8,
    certificate: []const u8,
};

const SecureWrite = struct {
    path: []const u8,
    bytes: []const u8,
    exclusive: bool,
};

pub const Pair = struct {
    key_pair: x509.KeyPair,
    cert_buf: [max_cert_len]u8 = undefined,
    cert_len: usize = 0,

    pub fn certDer(pair: *const Pair) []const u8 {
        return pair.cert_buf[0..pair.cert_len];
    }

    pub fn certPem(pair: *const Pair, buffer: []u8) Error![]const u8 {
        return x509.encodePem(buffer, x509.cert_label, pair.certDer()) catch error.WriteFailed;
    }

    pub fn keyPem(pair: *const Pair, buffer: []u8) Error![]const u8 {
        var der_buffer: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &der_buffer);
        const der = x509.encodePrivateKey(&der_buffer, pair.key_pair) catch return error.WriteFailed;
        return x509.encodePem(buffer, x509.key_label, der) catch error.WriteFailed;
    }
};

pub const Authority = struct {
    pair: Pair,

    /// Loads one complete authority or atomically creates both missing files.
    /// A partial key/certificate pair is rejected instead of being repaired.
    ///
    /// ```zig
    /// var authority = try Authority.loadOrCreate(resources, files);
    /// ```
    pub fn loadOrCreate(resources: Resources, files: AuthorityFiles) Error!Authority {
        const io = resources.io;
        const key_path = files.key;
        const cert_path = files.certificate;

        const key_exists = pathExists(io, key_path) catch return error.ReadFailed;
        const cert_exists = pathExists(io, cert_path) catch return error.ReadFailed;
        if (key_exists != cert_exists) return error.IncompleteAuthority;
        if (key_exists) {
            try validateStoredFile(io, key_path);
            try validateStoredFile(io, cert_path);
            return .{ .pair = try load(resources, files) };
        }

        var pair = try generate(io);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
        try persist(io, &pair, files);
        return .{ .pair = pair };
    }

    /// `SSL_CERT_FILE` replaces system trust. The child therefore receives a
    /// bundle containing both platform roots and Telar's private authority.
    ///
    /// ```zig
    /// try authority.writeBundle(resources, output_path);
    /// ```
    pub fn writeBundle(authority: *const Authority, resources: Resources, output_path: []const u8) Error!void {
        const io = resources.io;
        const gpa = resources.allocator;

        const roots = readSystemRoots(io, gpa) catch return error.ReadFailed;
        defer gpa.free(roots);
        var pem_buffer: [max_pem_len]u8 = undefined;
        const ours = try authority.pair.certPem(&pem_buffer);
        const bundle = std.mem.concat(gpa, u8, &.{ roots, ours }) catch return error.WriteFailed;
        defer gpa.free(bundle);
        try writeSecure(io, .{ .path = output_path, .bytes = bundle, .exclusive = false });
    }

    pub fn mint(authority: *const Authority, io: Io, host: []const u8) Error!Pair {
        const now = Io.Clock.real.now(io).toSeconds();
        var leaf: Pair = .{ .key_pair = x509.KeyPair.generate(io) };
        defer std.crypto.secureZero(u8, std.mem.asBytes(&leaf));
        const cert = x509.create(
            &leaf.cert_buf,
            .{
                .common_name = host,
                .dns_name = host,
                .serial = randomSerial(io),
                .not_before = now - backdate_seconds,
                .not_after = now + leaf_seconds,
            },
            leaf.key_pair.public_key,
            .{ .common_name = ca_common_name, .key_pair = &authority.pair.key_pair },
        ) catch return error.CertFailed;
        leaf.cert_len = cert.len;
        return leaf;
    }
};

fn generate(io: Io) Error!Pair {
    const now = Io.Clock.real.now(io).toSeconds();
    var pair: Pair = .{ .key_pair = x509.KeyPair.generate(io) };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    const cert = x509.create(
        &pair.cert_buf,
        .{
            .common_name = ca_common_name,
            .serial = randomSerial(io),
            .not_before = now - backdate_seconds,
            .not_after = now + ca_seconds,
            .is_ca = true,
        },
        pair.key_pair.public_key,
        .{ .common_name = ca_common_name, .key_pair = &pair.key_pair },
    ) catch return error.CertFailed;
    pair.cert_len = cert.len;
    return pair;
}

fn load(resources: Resources, files: AuthorityFiles) Error!Pair {
    const io = resources.io;
    const gpa = resources.allocator;

    const key_pem = Io.Dir.cwd().readFileAlloc(io, files.key, gpa, .limited(max_pem_len)) catch
        return error.ReadFailed;
    defer {
        std.crypto.secureZero(u8, key_pem);
        gpa.free(key_pem);
    }
    const cert_pem = Io.Dir.cwd().readFileAlloc(io, files.certificate, gpa, .limited(max_pem_len)) catch
        return error.ReadFailed;
    defer gpa.free(cert_pem);

    const parsed = tlsz.config.PrivateKey.parsePem(key_pem) catch return error.ReadFailed;
    if (parsed.signature_scheme != .ecdsa_secp256r1_sha256) return error.ReadFailed;
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    var secret = Ecdsa.SecretKey.fromBytes(
        parsed.key.ecdsa[0..Ecdsa.SecretKey.encoded_length].*,
    ) catch return error.ReadFailed;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&secret));
    var pair: Pair = .{
        .key_pair = x509.KeyPair.fromSecretKey(secret) catch return error.ReadFailed,
    };
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    const der = x509.decodePem(&pair.cert_buf, cert_pem) catch return error.ReadFailed;
    pair.cert_len = der.len;
    const parsed_cert = (std.crypto.Certificate{
        .buffer = pair.certDer(),
        .index = 0,
    }).parse() catch return error.ReadFailed;
    parsed_cert.verify(parsed_cert, Io.Clock.real.now(io).toSeconds()) catch
        return error.ReadFailed;
    const authority: Authority = .{ .pair = pair };
    var probe = authority.mint(io, "validation.telar.invalid") catch
        return error.ReadFailed;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&probe));
    const parsed_probe = (std.crypto.Certificate{
        .buffer = probe.certDer(),
        .index = 0,
    }).parse() catch return error.ReadFailed;
    parsed_probe.verify(parsed_cert, Io.Clock.real.now(io).toSeconds()) catch
        return error.ReadFailed;
    return pair;
}

fn persist(io: Io, pair: *const Pair, files: AuthorityFiles) Error!void {
    var buffer: [max_pem_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    // Create both destinations with 0600 from their first inode. Exclusive
    // creation refuses to overwrite another runtime's authority.
    try writeSecure(io, .{ .path = files.key, .bytes = try pair.keyPem(&buffer), .exclusive = true });
    writeSecure(io, .{ .path = files.certificate, .bytes = try pair.certPem(&buffer), .exclusive = true }) catch
        return error.IncompleteAuthority;
}

fn writeSecure(io: Io, write: SecureWrite) Error!void {
    const path = write.path;

    if (!std.fs.path.isAbsolute(path)) return error.WriteFailed;
    var temp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (0..8) |_| {
        const temp_path = std.fmt.bufPrint(
            &temp_buffer,
            "{s}.tmp-{x}",
            .{ path, randomSerial(io) },
        ) catch return error.WriteFailed;
        const file = Io.Dir.createFileAbsolute(io, temp_path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = File.Permissions.fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return error.WriteFailed,
        };
        file.writeStreamingAll(io, write.bytes) catch {
            file.close(io);
            Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
            return error.WriteFailed;
        };
        file.sync(io) catch {
            file.close(io);
            Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
            return error.WriteFailed;
        };
        file.close(io);
        const cwd = Io.Dir.cwd();
        if (write.exclusive) {
            Io.Dir.renamePreserve(cwd, temp_path, cwd, path, io) catch {
                Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
                return error.WriteFailed;
            };
        } else {
            Io.Dir.renameAbsolute(temp_path, path, io) catch {
                Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
                return error.WriteFailed;
            };
        }
        return;
    }
    return error.WriteFailed;
}

fn pathExists(io: Io, path: []const u8) !bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    return true;
}

fn validateStoredFile(io: Io, path: []const u8) Error!void {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch
        return error.ReadFailed;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0)
        return error.ReadFailed;
}

fn readSystemRoots(io: Io, gpa: std.mem.Allocator) ![]u8 {
    for ([_][]const u8{
        "/etc/ssl/cert.pem",
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/ca-bundle.pem",
    }) |path| return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch continue;
    return error.FileNotFound;
}

fn randomSerial(io: Io) u64 {
    const source: std.Random.IoSource = .{ .io = io };
    return source.interface().int(u64) >> 1;
}

test "minted leaves verify against the local authority" {
    const io = std.testing.io;
    const authority: Authority = .{ .pair = try generate(io) };
    const leaf = try authority.mint(io, "api.anthropic.com");
    const parsed_leaf = try (std.crypto.Certificate{ .buffer = leaf.certDer(), .index = 0 }).parse();
    const parsed_ca = try (std.crypto.Certificate{ .buffer = authority.pair.certDer(), .index = 0 }).parse();
    try parsed_leaf.verify(parsed_ca, Io.Clock.real.now(io).toSeconds());
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

    const resources: Resources = .{ .io = io, .allocator = gpa };
    const files: AuthorityFiles = .{ .key = key_path, .certificate = cert_path };
    var authority = try Authority.loadOrCreate(resources, files);
    try authority.writeBundle(resources, bundle_path);
    _ = try Authority.loadOrCreate(resources, files);
    for ([_][]const u8{ key_path, cert_path, bundle_path }) |path| {
        const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(File.Kind.file, stat.kind);
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    }
}
