const std = @import("std");
const core = @import("telar-core");
const ControlAgent = @import("ControlAgent.zig");
const control = @import("control.zig");
const workspace_output = @import("workspace_output.zig");

/// Emits one complete JSON line for an observable global event. Example: `if (try runtime_events.write(writer, event)) count += 1;`
pub fn write(writer: *std.Io.Writer, event: core.ServerMessage) !bool {
    switch (event) {
        .proxy_status => |value| try std.json.Stringify.value(.{ .type = "proxy_status", .data = value }, .{}, writer),
        .system_metrics => |value| try std.json.Stringify.value(.{ .type = "system_metrics", .data = value }, .{}, writer),
        .runtime_stopping => try writer.writeAll("{\"type\":\"runtime_stopping\"}"),
        .resync_required => try writer.writeAll("{\"type\":\"resync_required\"}"),
        .workspace_list => |snapshot| {
            try writer.print("{{\"type\":\"workspace_list\",\"revision\":{d},\"data\":[", .{snapshot.revision});
            var entries = snapshot.entries();
            var separator: []const u8 = "";
            while (try entries.next()) |entry| {
                try writer.writeAll(separator);
                try workspace_output.write(writer, entry, true);
                separator = ",";
            }

            try writer.writeAll("]}");
        },
        .agent_snapshot => |snapshot| {
            try writer.print("{{\"type\":\"agent_snapshot\",\"revision\":{d},\"data\":[", .{snapshot.revision});
            var entries = snapshot.entries();
            var separator: []const u8 = "";
            while (try entries.next()) |entry| {
                try writer.writeAll(separator);
                const agent = ControlAgent.fromEntry(entry);
                try control.writeAgentJson(writer, &agent);
                separator = ",";
            }

            try writer.writeAll("]}");
        },
        else => return false,
    }

    try writer.writeByte('\n');
    try writer.flush();
    return true;
}
