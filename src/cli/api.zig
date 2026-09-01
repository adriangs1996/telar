//! The `telar api schema` command: prints the exact wire contract the running
//! binary speaks so agents and scripts can check compatibility.

const std = @import("std");
const core = @import("telar-core");
const control = @import("control.zig");
const parser = @import("parser.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const handshake = core.handshake;

/// Prints the schema version, fingerprint, message tags and bounds.
///
/// ```zig
/// try api.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: parser.ApiOptions) !void {
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    defer writer.flush() catch {};

    if (options.json) {
        try writeJson(writer);
    } else {
        try writeText(writer);
    }
}

const Bound = struct {
    name: []const u8,
    value: usize,
};

const bounds = [_]Bound{
    .{ .name = "max_frame_bytes", .value = core.transport.max_frame_size },
    .{ .name = "max_agent_snapshot_entries", .value = schema.max_agent_snapshot_entries },
    .{ .name = "max_pane_text_rows", .value = schema.max_pane_text_rows },
    .{ .name = "max_pane_text_bytes", .value = schema.max_pane_text_bytes },
    .{ .name = "max_pane_text_input_bytes", .value = schema.max_pane_text_input_bytes },
    .{ .name = "max_history_results", .value = schema.max_history_results },
};

fn writeText(writer: *Io.Writer) !void {
    try writer.print("schema {s} fingerprint {s}\n\n", .{ handshake.schema_version, handshake.schema_id[2..] });
    try writer.writeAll("client requests\n");
    inline for (@typeInfo(schema.ClientTag).@"enum".fields) |field| {
        try writer.print("  0x{x:0>2}  {s}\n", .{ field.value, field.name });
    }
    try writer.writeAll("\nserver messages\n");
    inline for (@typeInfo(schema.ServerTag).@"enum".fields) |field| {
        try writer.print("  0x{x:0>2}  {s}\n", .{ field.value, field.name });
    }
    try writer.writeAll("\nagent statuses\n");
    inline for (@typeInfo(schema.AgentStatus).@"enum".fields) |field| {
        try writer.print("  {d}  {s}\n", .{ field.value, field.name });
    }
    try writer.writeAll("\nbounds\n");
    for (bounds) |bound| {
        try writer.print("  {s} = {d}\n", .{ bound.name, bound.value });
    }
}

fn writeJson(writer: *Io.Writer) !void {
    try writer.writeAll("{\"schema_version\":");
    try control.writeJsonString(writer, handshake.schema_version);
    try writer.writeAll(",\"fingerprint\":");
    try control.writeJsonString(writer, handshake.schema_id[2..]);
    try writer.writeAll(",\"client_requests\":{");
    try writeEnumJson(writer, schema.ClientTag);
    try writer.writeAll("},\"server_messages\":{");
    try writeEnumJson(writer, schema.ServerTag);
    try writer.writeAll("},\"agent_statuses\":{");
    try writeEnumJson(writer, schema.AgentStatus);
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

fn writeEnumJson(writer: *Io.Writer, comptime Enum: type) !void {
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
    var writer = Io.Writer.fixed(&buffer);

    try writeText(&writer);

    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "0x1c  query_agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "0xa0  pane_text") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5  done") != null);
}
