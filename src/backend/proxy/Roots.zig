const tlsz = @import("tls");
const std = @import("std");
const Roots = @This();

bundle: tlsz.config.cert.Bundle,

pub fn load(io: std.Io, gpa: std.mem.Allocator) !Roots {
    return .{ .bundle = try tlsz.config.cert.fromSystem(gpa, io) };
}

pub fn deinit(roots: *Roots, gpa: std.mem.Allocator) void {
    roots.bundle.deinit(gpa);
}
