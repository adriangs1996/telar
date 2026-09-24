const tlsz = @import("tls");
const std = @import("std");
const Roots = @This();

bundle: tlsz.config.cert.Bundle,

pub fn load(io: std.Io, gpa: std.mem.Allocator) !Roots {
    return .{ .bundle = try tlsz.config.cert.fromSystem(gpa, io) };
}

pub fn deinit(self: *Roots, gpa: std.mem.Allocator) void {
    self.bundle.deinit(gpa);
}
