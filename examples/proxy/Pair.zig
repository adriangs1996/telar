const Pair = @This();
const source_namespace = @import("ca.zig");
key_pair: source_namespace.x509.KeyPair,
cert_buf: [source_namespace.max_cert_len]u8 = undefined,
cert_len: usize = 0,

pub fn certDer(self: *const Pair) []const u8 {
    return self.cert_buf[0..self.cert_len];
}

/// Writes the certificate as PEM into `buf`.
///
/// A TLS stack takes bytes, not certificate objects, and PEM is the only
/// format both sides already agree on. Going through memory rather than a
/// temporary file keeps the private key out of the filesystem.
pub fn certPem(self: *const Pair, buf: []u8) source_namespace.Error![]const u8 {
    return source_namespace.x509.encodePem(buf, source_namespace.x509.cert_label, self.certDer()) catch error.WriteFailed;
}

/// Writes the private key as unencrypted PKCS#8 PEM into `buf`.
pub fn keyPem(self: *const Pair, buf: []u8) source_namespace.Error![]const u8 {
    var der_buf: [256]u8 = undefined;
    const der = source_namespace.x509.encodePrivateKey(&der_buf, self.key_pair) catch return error.WriteFailed;
    return source_namespace.x509.encodePem(buf, source_namespace.x509.key_label, der) catch error.WriteFailed;
}
