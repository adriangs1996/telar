const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const RuntimeOptions = @import("arguments/RuntimeOptions.zig");

/// Inspects an existing runtime without starting or attaching a pane. Example: `try runtime.run(init, options);`
pub fn run(init: std.process.Init, options: RuntimeOptions) !void {
    var session = try Session.attach(init, options.socket);
    defer session.close();
    try session.subscribeRuntime();

    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    while (true) {
        switch (try session.receive()) {
            .proxy_status => |status| {
                try writeStatus(&output.interface, status, options.json);
                try output.interface.flush();
                return;
            },
            else => {},
        }
    }
}

fn writeStatus(writer: *std.Io.Writer, status: core.ProxyStatus, json: bool) !void {
    if (json) {
        try std.json.Stringify.value(.{ .running = true, .schema_version = core.schema_version, .proxy = status }, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("Runtime: running\nSchema: {s}\nProxy: {s}\nProxy scope: {s}\nSystem trust: {s}\n", .{ core.schema_version, if (status.active) "active" else "disabled", @tagName(status.scope), if (status.system_trusted) "installed" else "absent" });
    }
}

test "runtime status JSON reports disabled proxy without claiming installed trust" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeStatus(&writer, .{ .active = false, .scope = .exact, .system_trusted = false }, true);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("running").?.bool);
    try std.testing.expect(!parsed.value.object.get("proxy").?.object.get("active").?.bool);
    try std.testing.expect(!parsed.value.object.get("proxy").?.object.get("system_trusted").?.bool);
}
