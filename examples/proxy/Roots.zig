/// The trust store used to verify real origins, loaded once per process.
///
/// Rescanning the platform roots costs a few milliseconds and an allocation per
/// connection, and every connection wants the same answer.
const Roots = @This();
const tlsz = @import("tls");
const source_namespace = @import("tls.zig");
const std = @import("std");
bundle: tlsz.config.cert.Bundle,

pub fn load(io: source_namespace.Io, gpa: std.mem.Allocator) !Roots {
    return .{ .bundle = try tlsz.config.cert.fromSystem(gpa, io) };
}

pub fn deinit(self: *Roots, gpa: std.mem.Allocator) void {
    self.bundle.deinit(gpa);
}
