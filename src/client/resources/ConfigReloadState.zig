const PluginOverrides = @import("PluginOverrides.zig");
const Orphans = @import("Orphans.zig");
const std = @import("std");
/// The reload's own state on the client: the watch fingerprint, the
/// generation counter, and the race-window handoff slots the async task
/// publishes into so a cancelled reload can still be freed.
const State = @This();

mtime_ns: i128,
force_next: bool = false,
plugin_overrides: PluginOverrides = .{},
next_generation: u64 = 2,
orphans: Orphans = .{},

/// Frees whatever a cancelled reload task published. Call only after
/// the client's producers have been cancelled and joined.
pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
    if (self.orphans.generation) |generation| {
        generation.deinit();
    }
    if (self.orphans.registry) |registry| {
        gpa.destroy(registry);
    }
    if (self.orphans.trust) |store| {
        gpa.destroy(store);
    }
}

pub fn clearOrphans(self: *State) void {
    self.orphans = .{};
}
