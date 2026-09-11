const Roots = @This();
const tlsz = @import("tls");
const source_namespace = @import("tls.zig");
const std = @import("std");
bundle: tlsz.config.cert.Bundle,

pub fn load(io: source_namespace.Io, gpa: std.mem.Allocator) !Roots {
    return .{ .bundle = try tlsz.config.cert.fromSystem(gpa, io) };
}

pub fn deinit(roots: *Roots, gpa: std.mem.Allocator) void {
    roots.bundle.deinit(gpa);
}
