const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const TabOptions = @import("arguments/TabOptions.zig");

/// Queries the tabs of an explicit or inherited workspace. Example: `try tab.run(init, options);`
pub fn run(init: std.process.Init, options: TabOptions) !void {
    const workspace = try options.workspace.resolve(init.minimal.environ, "TELAR_WORKSPACE_ID");
    var session = try Session.attach(init, options.socket);
    defer session.close();
    const response = try session.exchange(core.encodeRequestWorkspaceSnapshot, core.RequestWorkspaceSnapshot{
        .request_id = .none,
        .workspace = .{ .workspace = @enumFromInt(workspace) },
    });
    if (response != .workspace_snapshot) {
        return error.UnexpectedRuntimeResponse;
    }

    const snapshot = response.workspace_snapshot;
    if (snapshot.workspace != .workspace or core.raw(snapshot.workspace.workspace) != workspace) {
        return error.UnexpectedRuntimeResponse;
    }

    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    if (options.json) {
        try writer.writeByte('[');
    } else {
        try writer.writeAll("ID\tPOSITION\tPANES\tLABEL\n");
    }

    var tabs = snapshot.tabs();
    var first = true;
    while (try tabs.next()) |entry| {
        if (options.json) {
            if (!first) {
                try writer.writeByte(',');
            }

            try std.json.Stringify.value(.{ .workspace_id = workspace, .tab_id = core.raw(entry.tab_id), .position = entry.position, .pane_count = entry.pane_count, .label = entry.label }, .{}, writer);
        } else {
            try writer.print("{d}\t{d}\t{d}\t{s}\n", .{ core.raw(entry.tab_id), entry.position, entry.pane_count, entry.label });
        }

        first = false;
    }

    if (options.json) {
        try writer.writeAll("]\n");
    }

    try writer.flush();
}
