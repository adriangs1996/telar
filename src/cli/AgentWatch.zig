const std = @import("std");
const core = @import("telar-core");
const ManagedAgent = @import("ManagedAgent.zig");
const agent_output = @import("agent_output.zig");
const AgentWatch = @This();

managed: ManagedAgent,
writer: *std.Io.Writer,
count: ?u32,

/// Streams coalesced snapshots for one exact pane generation. Example: `try watch.run();`
pub fn run(self: *AgentWatch) !void {
    const session = self.managed.session;
    const snapshot = try session.gpa.create(core.AgentThreadSnapshot);
    defer session.gpa.destroy(snapshot);
    try self.managed.read(snapshot);
    try agent_output.thread(self.writer, snapshot, true);
    try self.writer.flush();
    var emitted: u64 = 1;
    if (self.count != null and self.count.? == emitted) {
        return;
    }

    try session.subscribeRuntime();
    while (true) {
        switch (try session.nextEvent()) {
            .agent_thread_snapshot => |view| {
                if (core.raw(view.pane_id) != self.managed.pane.pane_id or view.pane_generation != self.managed.pane.pane_generation or view.revision <= snapshot.revision) {
                    continue;
                }

                try view.copyTo(snapshot);
                try agent_output.thread(self.writer, snapshot, true);
                try self.writer.flush();
                emitted += 1;
                if (self.count != null and self.count.? == emitted) {
                    return;
                }
            },
            .agent_snapshot => |view| {
                var entries = view.entries();
                var found = false;
                while (try entries.next()) |entry| {
                    if (core.raw(entry.pane_id) == self.managed.pane.pane_id and entry.pane_generation == self.managed.pane.pane_generation) {
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    return error.AgentNotFound;
                }
            },
            .runtime_stopping => return,
            .resync_required => return error.RuntimeResyncRequired,
            else => {},
        }
    }
}
