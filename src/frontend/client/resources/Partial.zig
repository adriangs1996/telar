/// The pieces the async task has built so far, so every failure unwinds
/// through one place instead of repeating the partial free by hand.
const Partial = @This();
const lua_config = @import("../../config/root.zig");
const core = @import("telar-core");
const plugin_broker = @import("../../plugins/root.zig");
const std = @import("std");
const Orphans = @import("Orphans.zig");
generation: *lua_config.Generation,
trust: ?*core.plugin.TrustStore = null,
registry: ?*plugin_broker.Registry = null,

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
