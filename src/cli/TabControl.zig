const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const TabOptions = @import("arguments/TabOptions.zig");
const pane_output = @import("pane_output.zig");
const TabControl = @This();

session: *Session,
writer: *std.Io.Writer,
location: core.TabLocation,
options: TabOptions,

/// Executes one operation on a complete tab identity. Example: `try command.execute();`
pub fn execute(self: *TabControl) !void {
    switch (self.options.action) {
        .get => try self.read(),
        .rename => try self.rename(),
        .close => try self.close(),
        .move => try self.move(),
        .list => return error.InvalidTabAction,
    }
}

fn move(self: *TabControl) !void {
    const response = try self.session.exchange(core.encodeMoveTab, core.MoveTab{
        .request_id = .none,
        .location = self.location,
        .direction = self.options.direction.?,
        .relative_to = self.options.relative_to,
    });
    if (response != .tab_moved or !std.meta.eql(response.tab_moved.location, self.location)) {
        return error.UnexpectedRuntimeResponse;
    }

    if (self.options.json) {
        try std.json.Stringify.value(.{ .workspace_id = core.raw(self.location.workspace.workspace), .tab_id = core.raw(self.location.tab_id), .position = response.tab_moved.position }, .{}, self.writer);
        try self.writer.writeByte('\n');
    } else {
        try self.writer.print("tab {d} moved to position {d}\n", .{ core.raw(self.location.tab_id), response.tab_moved.position });
    }
}

fn read(self: *TabControl) !void {
    const response = try self.session.exchange(core.encodeRequestTabSnapshot, core.RequestTabSnapshot{ .request_id = .none, .location = self.location });
    if (response != .tab_snapshot or !std.meta.eql(response.tab_snapshot.location, self.location)) {
        return error.UnexpectedRuntimeResponse;
    }

    try self.writeSnapshot(response.tab_snapshot);
}

fn rename(self: *TabControl) !void {
    const response = try self.session.exchange(core.encodeRenameTab, core.RenameTab{ .request_id = .none, .location = self.location, .label = std.mem.span(self.options.label.?) });
    if (response != .tab_renamed or !std.meta.eql(response.tab_renamed.location, self.location)) {
        return error.UnexpectedRuntimeResponse;
    }

    if (self.options.json) {
        try std.json.Stringify.value(.{ .workspace_id = core.raw(self.location.workspace.workspace), .tab_id = core.raw(self.location.tab_id), .label = response.tab_renamed.label }, .{}, self.writer);
        try self.writer.writeByte('\n');
    } else {
        try self.writer.print("tab {d} renamed to {s}\n", .{ core.raw(self.location.tab_id), response.tab_renamed.label });
    }
}

fn close(self: *TabControl) !void {
    const response = try self.session.exchange(core.encodeCloseTab, core.CloseTab{ .request_id = .none, .location = self.location });
    if (response != .tab_closed or !std.meta.eql(response.tab_closed.location, self.location)) {
        return error.UnexpectedRuntimeResponse;
    }

    if (self.options.json) {
        try std.json.Stringify.value(.{ .workspace_id = core.raw(self.location.workspace.workspace), .tab_id = core.raw(self.location.tab_id), .closed = true, .workspace_closed = response.tab_closed.workspace_closed }, .{}, self.writer);
        try self.writer.writeByte('\n');
    } else {
        try self.writer.print("tab {d} closed\n", .{core.raw(self.location.tab_id)});
    }
}

fn writeSnapshot(self: *TabControl, snapshot: core.TabSnapshotView) !void {
    const writer = self.writer;
    const json = self.options.json;
    if (json) {
        try writer.print("{{\"workspace_id\":{d},\"tab_id\":{d},\"panes\":[", .{ core.raw(snapshot.location.workspace.workspace), core.raw(snapshot.location.tab_id) });
    } else {
        try writer.writeAll("PANE\tGENERATION\tKIND\tLIFECYCLE\n");
    }

    var panes = snapshot.panes();
    var first = true;
    while (try panes.next()) |pane| {
        if (json and !first) {
            try writer.writeByte(',');
        }

        try pane_output.write(writer, pane, json);
        first = false;
    }

    if (json) {
        try writer.writeAll("]}\n");
    }
}
