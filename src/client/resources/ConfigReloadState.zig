const Orphans = @import("Orphans.zig");
const std = @import("std");
/// The reload's own state on the client: the watch fingerprint, the
/// generation counter, and the race-window handoff slots the async task
/// publishes into so a cancelled reload can still be freed.
const State = @This();

mtime_ns: i128,
next_generation: u64 = 2,
orphans: Orphans = .{},

/// Frees whatever a cancelled reload task published. Call only after
/// the select's tasks are cancelled.
pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
    if (state.orphans.generation) |generation| {
        generation.deinit();
    }
    if (state.orphans.registry) |registry| {
        gpa.destroy(registry);
    }
    if (state.orphans.trust) |store| {
        gpa.destroy(store);
    }
}

pub fn clearOrphans(state: *State) void {
    state.orphans = .{};
}
