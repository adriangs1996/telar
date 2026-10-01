const std = @import("std");
const core = @import("telar-core");
const ExecutionPipes = @import("ExecutionPipes.zig");
const ClientKey = @import("../history/ClientKey.zig");
const Executions = @This();

pub const capacity = 32;
pub const limit = core.Limit.declare("executions.capacity", "retained executions", capacity);

id: [capacity]u64 = @splat(0),
launch_hash: [capacity][std.crypto.hash.sha2.Sha256.digest_length]u8 = @splat(@splat(0)),
workspace: [capacity]core.WorkspaceId = @splat(.invalid),
state: [capacity]core.ExecutionReply.State = @splat(.starting),
exit_code: [capacity]i32 = @splat(0),
failure: [capacity]?anyerror = @splat(null),
stdin_owner: [capacity]?ClientKey = @splat(null),
pipes: [capacity]?*ExecutionPipes = @splat(null),
count: usize = 0,
index: core.GenericSlotIndex(2 * capacity) = .{},

/// Finds a stable execution identity. Example: `const slot = executions.find(id);`.
pub fn find(self: *const Executions, id: u64) ?usize {
    if (id == 0) {
        return null;
    }

    return self.index.get(id);
}

/// Reserves a row; results are never silently evicted. Example: `try executions.add(id);`.
pub fn add(self: *Executions, id: u64) !usize {
    for (&self.id, 0..) |*candidate, slot| {
        if (candidate.* == 0) {
            candidate.* = id;
            self.state[slot] = .starting;
            self.exit_code[slot] = 0;
            self.failure[slot] = null;
            self.count += 1;
            self.index.put(id, slot);
            return slot;
        }
    }

    return error.ExecutionLimitReached;
}

/// Removes a joined execution. Example: `executions.remove(gpa, slot);`.
pub fn remove(self: *Executions, gpa: std.mem.Allocator, slot: usize) void {
    if (self.pipes[slot]) |pipes| {
        pipes.destroy(gpa);
    }

    self.index.remove(self.id[slot]);
    self.pipes[slot] = null;
    self.stdin_owner[slot] = null;
    self.id[slot] = 0;
    self.count -= 1;
}
