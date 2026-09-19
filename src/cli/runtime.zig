const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const RuntimeOptions = @import("arguments/RuntimeOptions.zig");
const runtime_events = @import("runtime_events.zig");
const control = @import("control.zig");

/// Inspects an existing runtime without starting or attaching a pane. Example: `const status = runtime.run(init, options);`
pub fn run(init: std.process.Init, options: RuntimeOptions) u8 {
    execute(init, options) catch |err| {
        std.debug.print("telar runtime: {s}\n", .{control.describe(err)});
        return if (err == error.RuntimeTimeout) 3 else 1;
    };

    return 0;
}

fn execute(init: std.process.Init, options: RuntimeOptions) !void {
    var session = try Session.attach(init, options.socket);
    defer session.close();
    try session.subscribeRuntime();

    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    if (options.action == .watch) {
        var count: u64 = 0;
        while (true) {
            const event = try session.nextEvent();
            if (try runtime_events.write(&output.interface, event)) {
                count += 1;
            }

            if (event == .resync_required) {
                return error.RuntimeResyncRequired;
            }
            if (event == .runtime_stopping or (options.count != null and count >= options.count.?)) {
                return;
            }
        }
    }

    while (true) {
        switch (try session.receive()) {
            .proxy_status => |status| {
                if (options.action != .status) {
                    continue;
                }

                try writeStatus(&output.interface, status, options.json);
                try output.interface.flush();
                return;
            },
            .system_metrics => |metrics| {
                if (options.action != .metrics) {
                    continue;
                }

                try writeMetrics(&output.interface, metrics, options.json);
                try output.interface.flush();
                return;
            },
            else => {},
        }
    }
}

fn writeMetrics(writer: *std.Io.Writer, metrics: core.SystemMetrics, json: bool) !void {
    if (json) {
        const battery: ?u8 = if (metrics.has_battery) metrics.battery_percent else null;
        try std.json.Stringify.value(.{ .revision = metrics.revision, .cpu_percent = metrics.cpu_percent, .memory_used_decigib = metrics.memory_used_decigib, .battery_percent = battery }, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("CPU: {d}%\nMemory: {d}.{d} GiB\n", .{ metrics.cpu_percent, metrics.memory_used_decigib / 10, metrics.memory_used_decigib % 10 });
        if (metrics.has_battery) {
            try writer.print("Battery: {d}%\n", .{metrics.battery_percent});
        } else {
            try writer.writeAll("Battery: unavailable\n");
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
