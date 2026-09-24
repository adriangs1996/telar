const tls = @import("tls");
const ca = @import("ca.zig");
const std = @import("std");
const Pair = @This();

key_pair: tls.x509.KeyPair,
cert_buf: [ca.max_cert_len]u8 = undefined,
cert_len: usize = 0,

pub fn certDer(self: *const Pair) []const u8 {
    return self.cert_buf[0..self.cert_len];
}

pub fn certPem(self: *const Pair, buffer: []u8) ca.Error![]const u8 {
    return tls.x509.encodePem(buffer, tls.x509.cert_label, self.certDer()) catch error.WriteFailed;
}

pub fn keyPem(self: *const Pair, buffer: []u8) ca.Error![]const u8 {
    var der_buffer: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &der_buffer);
    const der = tls.x509.encodePrivateKey(&der_buffer, self.key_pair) catch return error.WriteFailed;
    return tls.x509.encodePem(buffer, tls.x509.key_label, der) catch error.WriteFailed;
}
