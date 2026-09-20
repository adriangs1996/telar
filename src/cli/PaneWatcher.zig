const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const PaneCatalog = @import("PaneCatalog.zig");
const PaneOptions = @import("arguments/PaneOptions.zig");
const ExecutionContext = @import("ExecutionContext.zig");
const control = @import("control.zig");
const Watcher = @This();
session: *Session,
options: PaneOptions,
context: ExecutionContext,

/// Streams changed text snapshots for one observed generation. Example: `try watcher.run();`
pub fn run(self: *Watcher) !void {
    const wanted = switch (self.options.target) {
        .current => try control.currentPaneId(self.context.environ),
        .pane => |id| id,
        .name => return error.InvalidPaneId,
    };
    var catalog: PaneCatalog = .{
        .session = self.session,
        .workspace = if (self.options.workspace) |target| try core.workspace(try target.resolve(self.context.environ, "TELAR_WORKSPACE_ID")) else null,
        .tab = if (self.options.tab) |target| try core.tab(try target.resolve(self.context.environ, "TELAR_TAB_ID")) else null,
    };
    try catalog.load();
    const pane = for (catalog.entries[0..catalog.count]) |entry| {
        if (core.raw(entry.pane.pane_id) == wanted) {
            break entry.pane;
        }
    } else return error.PaneNotFound;
    var previous: ?[32]u8 = null;
    var previous_truncated = false;
    var count: u64 = 0;
    while (true) {
        const response = try self.session.exchange(core.encodeReadPane, core.ReadPane{ .request_id = .none, .pane_id = pane.pane_id, .pane_generation = pane.pane_generation, .rows = self.options.lines, .source = self.options.source });
        if (response != .pane_text or response.pane_text.pane_id != pane.pane_id) {
            return error.UnexpectedRuntimeResponse;
        }

        const text = response.pane_text;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text.text, &digest, .{});
        if (previous == null or !std.mem.eql(u8, &previous.?, &digest) or previous_truncated != text.truncated) {
            try std.json.Stringify.value(.{ .pane_id = wanted, .pane_generation = pane.pane_generation, .truncated = text.truncated, .text = text.text }, .{}, self.context.writer);
            try self.context.writer.writeByte('\n');
            try self.context.writer.flush();
            count += 1;
            previous = digest;
            previous_truncated = text.truncated;
            if (self.options.count != null and count >= self.options.count.?) {
                return;
            }
        }

        try self.session.io.sleep(.fromMilliseconds(self.options.interval_ms), .awake);
    }
}
