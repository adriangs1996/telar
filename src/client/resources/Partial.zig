const core = @import("telar-core");
const Generation = @import("../config/Generation.zig");
const Registry = @import("../plugins/Registry.zig");
const std = @import("std");
const Orphans = @import("Orphans.zig");
/// The pieces the async task has built so far, so every failure unwinds
/// through one place instead of repeating the partial free by hand.
const Partial = @This();

generation: *Generation,
trust: ?*core.TrustStore = null,
registry: ?*Registry = null,

pub fn abandon(partial: Partial, gpa: std.mem.Allocator, orphans: *Orphans) void {
    orphans.* = .{};
    if (partial.registry) |registry| {
        gpa.destroy(registry);
    }
    partial.generation.deinit();
    if (partial.trust) |trust| {
        gpa.destroy(trust);
    }
}
