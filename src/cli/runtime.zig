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
            const selected = !options.proxy_only or event == .proxy_status or event == .runtime_stopping or event == .resync_required;
            if (selected and try runtime_events.write(&output.interface, event)) {
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
        try std.json.Stringify.value(.{ .revision = metrics.revision, .cpu_percent = metrics.cpu_percent, .memory_used_decigib = metrics.memory_used_decigib, .memory_total_decigib = metrics.memory_total_decigib, .cpu_count = metrics.cpu_count, .battery_percent = battery }, .{}, writer);
        try writer.writeByte('\n');
    } else {
        try writer.print("CPU: {d}% of {d}\nMemory: {d}.{d} of {d}.{d} GiB\n", .{
            metrics.cpu_percent,
            metrics.cpu_count,
            metrics.memory_used_decigib / 10,
            metrics.memory_used_decigib % 10,
            metrics.memory_total_decigib / 10,
            metrics.memory_total_decigib % 10,
        });
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
        try writer.print("Runtime: running\nSchema: {s}\nProxy: {s}\n", .{ core.schema_version, if (status.active) "active" else "disabled" });
        try writeProxyPort(writer, status);
        try writer.print("Proxy scope: {s}\nSystem trust: {s}\n", .{ @tagName(status.scope), if (status.system_trusted) "installed" else "absent" });
    }
}

fn writeProxyPort(writer: *std.Io.Writer, status: core.ProxyStatus) !void {
    const port = status.port orelse return;
    const preferred = status.preferred_port orelse {
        try writer.print("Proxy port: {d} (none remembered for this runtime)\n", .{port});
        return;
    };

    if (preferred == port) {
        try writer.print("Proxy port: {d}\n", .{port});
        return;
    }

    try writer.print(
        "Proxy port: {d} (warning: remembered port {d} was held by another process; processes that inherited it do not reach this runtime)\n",
        .{ port, preferred },
    );
}

test "runtime status names the proxy port and warns when the remembered one was taken" {
    var buffer: [1024]u8 = undefined;
    var kept = std.Io.Writer.fixed(&buffer);
    try writeStatus(
        &kept,
        .{
            .active = true,
            .scope = .exact,
            .system_trusted = false,
            .port = 45104,
            .preferred_port = 45104,
        },
        false,
    );
    try std.testing.expect(std.mem.indexOf(u8, kept.buffered(), "Proxy port: 45104\n") != null);

    var displaced_buffer: [1024]u8 = undefined;
    var displaced = std.Io.Writer.fixed(&displaced_buffer);
    try writeStatus(
        &displaced,
        .{
            .active = true,
            .scope = .exact,
            .system_trusted = false,
            .port = 45105,
            .preferred_port = 45104,
        },
        false,
    );
    try std.testing.expect(std.mem.indexOf(u8, displaced.buffered(), "Proxy port: 45105 (warning: remembered port 45104 was held by another process") != null);

    var disabled_buffer: [1024]u8 = undefined;
    var disabled = std.Io.Writer.fixed(&disabled_buffer);
    try writeStatus(
        &disabled,
        .{
            .active = false,
            .scope = .exact,
            .system_trusted = false,
        },
        false,
    );
    try std.testing.expect(std.mem.indexOf(u8, disabled.buffered(), "Proxy port") == null);
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
