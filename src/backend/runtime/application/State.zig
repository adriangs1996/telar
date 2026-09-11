const State = @This();
const OwnedWrite = @import("OwnedWrite.zig");
const source_namespace = @import("session_checkpoint.zig");
const std = @import("std");
path: ?[]const u8 = null,
/// Type the agent's resume command into a restored pane's shell.
resume_agents: bool = true,
dirty: bool = false,
pending: ?OwnedWrite = null,
last_change_ns: u64 = 0,
writes: u64 = 0,
failures: u64 = 0,
restored_workspaces: u16 = 0,
restored_panes: u16 = 0,
resumed_agents: u16 = 0,
/// Restored tabs dropped because none of their panes came back.
dropped_tabs: u16 = 0,
restore_failed: bool = false,

pub fn enabled(state: *const State) bool {
    return state.path != null;
}

/// Records one semantic change; the next due tick persists it.
///
/// ```zig
/// state.noteChange(now_ns);
/// ```
pub fn noteChange(state: *State, now_ns: u64) void {
    if (!state.enabled()) {
        return;
    }
    state.dirty = true;
    state.last_change_ns = now_ns;
}

/// Reports whether a write should start now: dirty, settled for the
/// debounce window and no write in flight.
///
/// ```zig
/// if (state.due(now_ns)) startWrite();
/// ```
pub fn due(state: *const State, now_ns: u64) bool {
    return state.enabled() and state.dirty and state.pending == null and
        now_ns -| state.last_change_ns >= source_namespace.debounce_ns;
}

/// Takes ownership before scheduling and releases it on startup failure.
/// Example: `try state.startWrite(owned, select);`.
pub fn startWrite(state: *State, owned: OwnedWrite, scheduler: anytype) !void {
    std.debug.assert(state.pending == null);
    state.pending = owned;
    state.dirty = false;
    scheduler.concurrent(.checkpoint_written, source_namespace.writeFile, .{owned.job}) catch |err| {
        state.completeWrite(err);
        return err;
    };
}

/// Completes one write. A failure keeps the checkpoint dirty so the next
/// tick retries; a change that arrived during the write stays dirty too.
///
/// ```zig
/// state.completeWrite(result);
/// ```
pub fn completeWrite(state: *State, result: anyerror!void) void {
    const owned = state.pending orelse return;
    state.pending = null;
    owned.allocator.free(owned.job.buffer);

    if (result) |_| {
        state.writes += 1;
    } else |_| {
        state.failures += 1;
        state.dirty = true;
    }
}
