const std = @import("std");
const Io = std.Io;

const tlsz = @import("tls");
const x509 = tlsz.x509;

// The local certificate authority.
//
// Interception needs a certificate the child will accept for a host we do not
// own, so we mint one per host and sign it with a CA the child has been told to
// trust. That CA key is the most dangerous object this PoC creates: anyone
// holding it can impersonate any site to any process that trusts it. It is
// written 0600, never leaves the machine, and is generated per machine.
//
// This was the last module that needed OpenSSL. `tls.zig`'s `x509` module now
// emits the certificates, so nothing on this path crosses into C.

pub const Error = error{
    KeygenFailed,
    CertFailed,
    SignFailed,
    WriteFailed,
    ReadFailed,
};

/// Ten years: this is a local development CA, and a short-lived one only means
/// re-injecting it into trust stores.
const ca_seconds: i64 = 3650 * 24 * 60 * 60;
/// Leaves are minted on demand, so they can be short.
const leaf_seconds: i64 = 30 * 24 * 60 * 60;
/// An hour of slack before `not_before`, to absorb clock skew between this
/// machine and whatever is checking.
const backdate_seconds: i64 = 3600;

/// Certificates issued here carry one common name and one DNS name, so they
/// stay well under this. The check in `x509.create` is what enforces it.
const max_cert_len = 1024;
const max_pem_len = 2 * max_cert_len;

pub const Resources = struct {
    io: Io,
    allocator: std.mem.Allocator,
};

pub const AuthorityFiles = struct {
    key: []const u8,
    certificate: []const u8,
};

pub const Pair = struct {
    key_pair: x509.KeyPair,
    cert_buf: [max_cert_len]u8 = undefined,
    cert_len: usize = 0,

    pub fn certDer(self: *const Pair) []const u8 {
        return self.cert_buf[0..self.cert_len];
    }

    /// Writes the certificate as PEM into `buf`.
    ///
    /// A TLS stack takes bytes, not certificate objects, and PEM is the only
    /// format both sides already agree on. Going through memory rather than a
    /// temporary file keeps the private key out of the filesystem.
    pub fn certPem(self: *const Pair, buf: []u8) Error![]const u8 {
        return x509.encodePem(buf, x509.cert_label, self.certDer()) catch error.WriteFailed;
    }

    /// Writes the private key as unencrypted PKCS#8 PEM into `buf`.
    pub fn keyPem(self: *const Pair, buf: []u8) Error![]const u8 {
        var der_buf: [256]u8 = undefined;
        const der = x509.encodePrivateKey(&der_buf, self.key_pair) catch return error.WriteFailed;
        return x509.encodePem(buf, x509.key_label, der) catch error.WriteFailed;
    }
};

pub const Authority = struct {
    pair: Pair,

    /// Loads the CA from `key_path`/`cert_path`, generating and persisting one
    /// on first run.
    pub fn loadOrCreate(resources: Resources, files: AuthorityFiles) Error!Authority {
        if (load(resources, files)) |pair| {
            return .{ .pair = pair };
        } else |_| {}

        const pair = try generate(resources.io);
        try persist(resources.io, pair, files.key, files.certificate);
        return .{ .pair = pair };
    }

    /// Writes the system roots followed by our CA into one PEM bundle.
    ///
    /// Pointing a child at our CA *alone* is the trap: `SSL_CERT_FILE` replaces
    /// the trust store rather than extending it, so every connection that does
    /// not go through the proxy — and every tool that talks to something else —
    /// starts failing with "unable to get issuer cert". The child must trust the
    /// real world plus us.
    pub fn writeBundle(self: *const Authority, resources: Resources, out_path: []const u8) Error!void {
        const io = resources.io;
        const gpa = resources.allocator;
        const cwd: Io.Dir = .cwd();

        const roots = readSystemRoots(io, gpa) catch &[_]u8{};
        defer if (roots.len > 0) gpa.free(roots);

        var pem_buf: [max_pem_len]u8 = undefined;
        const ours = try self.pair.certPem(&pem_buf);

        const bundle = std.mem.concat(gpa, u8, &.{ roots, ours }) catch return error.WriteFailed;
        defer gpa.free(bundle);

        cwd.writeFile(io, .{ .sub_path = out_path, .data = bundle }) catch return error.WriteFailed;
    }

    /// Mints a leaf certificate for `host`, signed by this authority.
    pub fn mint(self: *const Authority, io: Io, host: []const u8) Error!Pair {
        const now = Io.Clock.real.now(io).toSeconds();

        var leaf: Pair = .{ .key_pair = x509.KeyPair.generate(io) };
        const written = x509.create(
            &leaf.cert_buf,
            .{
                .common_name = host,
                .dns_name = host,
                // Must differ per certificate, or clients cache-collide them.
                .serial = randomSerial(io),
                .not_before = now - backdate_seconds,
                .not_after = now + leaf_seconds,
            },
            leaf.key_pair.public_key,
            .{ .common_name = ca_common_name, .key_pair = &self.pair.key_pair },
        ) catch return error.CertFailed;

        leaf.cert_len = written.len;
        return leaf;
    }
};

const ca_common_name = "herdr local CA";

fn generate(io: Io) Error!Pair {
    const now = Io.Clock.real.now(io).toSeconds();

    var pair: Pair = .{ .key_pair = x509.KeyPair.generate(io) };
    const written = x509.create(
        &pair.cert_buf,
        .{
            .common_name = ca_common_name,
            .serial = randomSerial(io),
            .not_before = now - backdate_seconds,
            .not_after = now + ca_seconds,
            .is_ca = true,
        },
        pair.key_pair.public_key,
        // Self-signed: the subject is its own issuer.
        .{ .common_name = ca_common_name, .key_pair = &pair.key_pair },
    ) catch return error.CertFailed;

    pair.cert_len = written.len;
    return pair;
}

fn load(resources: Resources, files: AuthorityFiles) Error!Pair {
    const io = resources.io;
    const gpa = resources.allocator;
    const cwd: Io.Dir = .cwd();

    const key_pem = cwd.readFileAlloc(io, files.key, gpa, .limited(max_pem_len)) catch return error.ReadFailed;
    defer gpa.free(key_pem);
    const cert_pem = cwd.readFileAlloc(io, files.certificate, gpa, .limited(max_pem_len)) catch return error.ReadFailed;
    defer gpa.free(cert_pem);

    const parsed = tlsz.config.PrivateKey.parsePem(key_pem) catch return error.ReadFailed;
    if (parsed.signature_scheme != .ecdsa_secp256r1_sha256) {
        return error.ReadFailed;
    }

    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const secret = Ecdsa.SecretKey.fromBytes(
        parsed.key.ecdsa[0..Ecdsa.SecretKey.encoded_length].*,
    ) catch return error.ReadFailed;

    var pair: Pair = .{
        .key_pair = x509.KeyPair.fromSecretKey(secret) catch return error.ReadFailed,
    };
    const der = x509.decodePem(&pair.cert_buf, cert_pem) catch return error.ReadFailed;
    pair.cert_len = der.len;
    return pair;
}

fn persist(io: Io, pair: Pair, key_path: []const u8, cert_path: []const u8) Error!void {
    const cwd: Io.Dir = .cwd();

    var buf: [max_pem_len]u8 = undefined;
    const cert_pem = try pair.certPem(&buf);
    cwd.writeFile(io, .{ .sub_path = cert_path, .data = cert_pem }) catch return error.WriteFailed;

    const key_pem = try pair.keyPem(&buf);
    cwd.writeFile(io, .{ .sub_path = key_path, .data = key_pem }) catch return error.WriteFailed;

    // Narrowed after the fact, because `std.Io.Dir.CreateFileOptions` has no
    // mode. That leaves a window where the key is readable, which a PoC can
    // wear and a shipped version cannot.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const key_path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{key_path}) catch return error.WriteFailed;
    if (std.c.chmod(key_path_z.ptr, 0o600) != 0) {
        return error.WriteFailed;
    }
}

/// The roots the platform ships, as PEM.
///
/// Not `std.crypto.Certificate.Bundle`: that parses them into its own in-memory
/// form, and what a child process needs is a file it can be pointed at.
fn readSystemRoots(io: Io, gpa: std.mem.Allocator) ![]u8 {
    const candidates = [_][]const u8{
        "/etc/ssl/cert.pem", // macOS, Alpine, OpenBSD
        "/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Gentoo
        "/etc/pki/tls/certs/ca-bundle.crt", // Fedora, RHEL
        "/etc/ssl/ca-bundle.pem", // openSUSE
    };
    const cwd: Io.Dir = .cwd();
    for (candidates) |path| {
        return cwd.readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch continue;
    }
    return error.NotFound;
}

/// A serial only has to be unpredictable enough not to repeat.
fn randomSerial(io: Io) u64 {
    const source: std.Random.IoSource = .{ .io = io };
    // The high bit is cleared so the DER integer stays comfortably positive
    // even before the encoder's own leading-zero rule.
    return source.interface().int(u64) >> 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a minted leaf verifies against the authority that signed it" {
    const io = testing.io;
    const authority: Authority = .{ .pair = try generate(io) };
    const leaf = try authority.mint(io, "api.anthropic.com");

    const Certificate = std.crypto.Certificate;
    const leaf_cert: Certificate = .{ .buffer = leaf.certDer(), .index = 0 };
    const ca_cert: Certificate = .{ .buffer = authority.pair.certDer(), .index = 0 };

    const parsed_leaf = try leaf_cert.parse();
    const parsed_ca = try ca_cert.parse();

    try parsed_leaf.verify(parsed_ca, Io.Clock.real.now(io).toSeconds());
    try parsed_leaf.verifyHostName("api.anthropic.com");
    try testing.expectError(
        error.CertificateHostMismatch,
        parsed_leaf.verifyHostName("evil.example"),
    );
}

test "serials differ between leaves" {
    const io = testing.io;
    const authority: Authority = .{ .pair = try generate(io) };
    const a = try authority.mint(io, "one.example");
    const b = try authority.mint(io, "two.example");
    try testing.expect(!std.mem.eql(u8, a.certDer(), b.certDer()));
}

test "the pem a leaf produces is what the tls stack expects" {
    // `CertKeyPair.fromSlice` is what consumes these, so it is the parser that
    // has to agree - not this file's idea of what PEM looks like.
    const io = testing.io;
    const gpa = testing.allocator;

    const authority: Authority = .{ .pair = try generate(io) };
    const leaf = try authority.mint(io, "localhost");

    var chain_buf: [max_pem_len]u8 = undefined;
    const leaf_pem = try leaf.certPem(&chain_buf);
    const ca_pem = try authority.pair.certPem(chain_buf[leaf_pem.len..]);

    var key_buf: [max_pem_len]u8 = undefined;
    const key_pem = try leaf.keyPem(&key_buf);

    var auth = try tlsz.config.CertKeyPair.fromSlice(
        gpa,
        io,
        chain_buf[0 .. leaf_pem.len + ca_pem.len],
        key_pem,
    );
    defer auth.deinit(gpa);

    // Leaf first, then the issuer, so a client that pinned only the root can
    // still build a chain.
    try testing.expectEqual(@as(usize, 2), auth.bundle.map.size);
    try testing.expectEqual(.ecdsa_secp256r1_sha256, auth.key.signature_scheme);
}
