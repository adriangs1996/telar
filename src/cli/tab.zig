const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const TabOptions = @import("arguments/TabOptions.zig");
const TabControl = @import("TabControl.zig");
const control = @import("control.zig");

/// Queries the tabs of an explicit or inherited workspace. Example: `const status = tab.run(init, options);`
pub fn run(init: std.process.Init, options: TabOptions) u8 {
    execute(init, options) catch |err| {
        std.debug.print("telar tab: {s}\n", .{control.describe(err)});
        return if (err == error.RuntimeTimeout) 3 else 1;
    };

    return 0;
}

fn execute(init: std.process.Init, options: TabOptions) !void {
    const workspace = try options.workspace.resolve(init.minimal.environ, "TELAR_WORKSPACE_ID");
    var session = try Session.attach(init, options.socket);
    defer session.close();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    if (options.target) |target| {
        const tab_id = try target.resolve(init.minimal.environ, "TELAR_TAB_ID");
        var command: TabControl = .{
            .session = &session,
            .writer = writer,
            .location = .{ .workspace = .{ .workspace = @enumFromInt(workspace) }, .tab_id = @enumFromInt(tab_id) },
            .options = options,
        };
        try command.execute();
        try writer.flush();
        return;
    }

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
