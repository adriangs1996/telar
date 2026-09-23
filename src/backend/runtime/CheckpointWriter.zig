const OwnedWrite = @import("application/OwnedWrite.zig");
const session_checkpoint = @import("session_checkpoint.zig");
const std = @import("std");
/// The session checkpoint's write-behind state: where it goes, whether the
/// model changed since the last write, and the one write in flight.
const CheckpointWriter = @This();

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

pub fn enabled(self: *const CheckpointWriter) bool {
    return self.path != null;
}

/// Records one semantic change; the next due tick persists it.
///
/// ```zig
/// checkpoint.noteChange(now_ns);
/// ```
pub fn noteChange(self: *CheckpointWriter, now_ns: u64) void {
    if (!self.enabled()) {
        return;
    }
    self.dirty = true;
    self.last_change_ns = now_ns;
}

/// Reports whether a write should start now: dirty, settled for the
/// debounce window and no write in flight.
///
/// ```zig
/// if (checkpoint.due(now_ns)) startWrite();
/// ```
pub fn due(self: *const CheckpointWriter, now_ns: u64) bool {
    return self.enabled() and self.dirty and self.pending == null and
        now_ns -| self.last_change_ns >= session_checkpoint.debounce_ns;
}

/// Takes ownership before scheduling and releases it on startup failure.
/// Example: `try checkpoint.startWrite(owned, select);`.
pub fn startWrite(self: *CheckpointWriter, owned: OwnedWrite, scheduler: anytype) !void {
    std.debug.assert(self.pending == null);
    self.pending = owned;
    self.dirty = false;
    scheduler.concurrent(.checkpoint_written, session_checkpoint.writeFile, .{owned.job}) catch |err| {
        self.completeWrite(err);
        return err;
    };
}

/// Completes one write. A failure keeps the checkpoint dirty so the next
/// tick retries; a change that arrived during the write stays dirty too.
///
/// ```zig
/// checkpoint.completeWrite(result);
/// ```
pub fn completeWrite(self: *CheckpointWriter, result: anyerror!void) void {
    if (!self.releaseWrite()) {
        return;
    }

    if (result) |_| {
        self.writes += 1;
    } else |_| {
        self.failures += 1;
        self.dirty = true;
    }
}

/// Releases a write whose worker has been joined and whose completion was
/// discarded during shutdown. Its outcome is unknown; the final write must
/// replace it before the model is destroyed.
/// Example: `checkpoint.discardJoinedWrite();` after `loop.cancel()`.
pub fn discardJoinedWrite(self: *CheckpointWriter) void {
    if (self.releaseWrite()) {
        self.dirty = true;
    }
}

fn releaseWrite(self: *CheckpointWriter) bool {
    const owned = self.pending orelse return false;
    self.pending = null;
    owned.allocator.free(owned.job.buffer);
    return true;
}
