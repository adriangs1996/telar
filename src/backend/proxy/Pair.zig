const Pair = @This();
const source_namespace = @import("ca.zig");
const std = @import("std");
key_pair: source_namespace.x509.KeyPair,
cert_buf: [source_namespace.max_cert_len]u8 = undefined,
cert_len: usize = 0,

pub fn certDer(pair: *const Pair) []const u8 {
    return pair.cert_buf[0..pair.cert_len];
}

pub fn certPem(pair: *const Pair, buffer: []u8) source_namespace.Error![]const u8 {
    return source_namespace.x509.encodePem(buffer, source_namespace.x509.cert_label, pair.certDer()) catch error.WriteFailed;
}

pub fn keyPem(pair: *const Pair, buffer: []u8) source_namespace.Error![]const u8 {
    var der_buffer: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &der_buffer);
    const der = source_namespace.x509.encodePrivateKey(&der_buffer, pair.key_pair) catch return error.WriteFailed;
    return source_namespace.x509.encodePem(buffer, source_namespace.x509.key_label, der) catch error.WriteFailed;
}
