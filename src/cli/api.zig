//! The `telar api schema` command: prints the exact wire contract the running
//! binary speaks so agents and scripts can check compatibility.

const std = @import("std");
const ApiOptionsType = @import("arguments/ApiOptions.zig");
const Bound = @import("Bound.zig");
const max_frame_size_module = @import("telar-core").max_frame_size;
const max_agent_snapshot_entries_module = @import("telar-core").max_agent_snapshot_entries;
const max_pane_text_rows_module = @import("telar-core").max_pane_text_rows;
const max_pane_text_bytes_module = @import("telar-core").max_pane_text_bytes;
const max_pane_text_input_bytes_module = @import("telar-core").max_pane_text_input_bytes;
const max_history_results_module = @import("telar-core").max_history_results;
const schema_version_module = @import("telar-core").schema_version;
const schema_id_module = @import("telar-core").schema_id;
const ClientTagType = @import("telar-core").ClientTag;
const ServerTagType = @import("telar-core").ServerTag;
const AgentStatusType = @import("telar-core").AgentStatus;
const control = @import("control.zig");

/// Prints the schema version, fingerprint, message tags and bounds.
///
/// ```zig
/// try api.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: ApiOptionsType) !void {
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    if (options.json) {
        try writeJson(writer);
    } else {
        try writeText(writer);
    }
}

const bounds = [_]Bound{
    .{ .name = "max_frame_bytes", .value = max_frame_size_module },
    .{ .name = "max_agent_snapshot_entries", .value = max_agent_snapshot_entries_module },
    .{ .name = "max_pane_text_rows", .value = max_pane_text_rows_module },
    .{ .name = "max_pane_text_bytes", .value = max_pane_text_bytes_module },
    .{ .name = "max_pane_text_input_bytes", .value = max_pane_text_input_bytes_module },
    .{ .name = "max_history_results", .value = max_history_results_module },
};

fn writeText(writer: *std.Io.Writer) !void {
    try writer.print("schema {s} fingerprint {s}\n\n", .{ schema_version_module, schema_id_module[2..] });
    try writer.writeAll("client requests\n");
    inline for (@typeInfo(ClientTagType).@"enum".fields) |field| {
        try writer.print("  0x{x:0>2}  {s}\n", .{ field.value, field.name });
    }
    try writer.writeAll("\nserver messages\n");
    inline for (@typeInfo(ServerTagType).@"enum".fields) |field| {
        try writer.print("  0x{x:0>2}  {s}\n", .{ field.value, field.name });
    }
    try writer.writeAll("\nagent statuses\n");
    inline for (@typeInfo(AgentStatusType).@"enum".fields) |field| {
        try writer.print("  {d}  {s}\n", .{ field.value, field.name });
    }
    try writer.writeAll("\nbounds\n");
    for (bounds) |bound| {
        try writer.print("  {s} = {d}\n", .{ bound.name, bound.value });
    }
}

fn writeJson(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"schema_version\":");
    try control.writeJsonString(writer, schema_version_module);
    try writer.writeAll(",\"fingerprint\":");
    try control.writeJsonString(writer, schema_id_module[2..]);
    try writer.writeAll(",\"client_requests\":{");
    try writeEnumJson(writer, ClientTagType);
    try writer.writeAll("},\"server_messages\":{");
    try writeEnumJson(writer, ServerTagType);
    try writer.writeAll("},\"agent_statuses\":{");
    try writeEnumJson(writer, AgentStatusType);
    try writer.writeAll("},\"bounds\":{");
    for (bounds, 0..) |bound, index| {
        if (index != 0) {
            try writer.writeByte(',');
        }

        try control.writeJsonString(writer, bound.name);
        try writer.print(":{d}", .{bound.value});
    }
    try writer.writeAll("}}\n");
}

fn writeEnumJson(writer: *std.Io.Writer, comptime Enum: type) !void {
    inline for (@typeInfo(Enum).@"enum".fields, 0..) |field, index| {
        if (index != 0) {
            try writer.writeByte(',');
        }

        try control.writeJsonString(writer, field.name);
        try writer.print(":{d}", .{field.value});
    }
}

test "the schema listing names every client tag once" {
    var buffer: [8 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeText(&writer);

    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "0x1c  query_agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "0xa0  pane_text") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5  done") != null);
}
