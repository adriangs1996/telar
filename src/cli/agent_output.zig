const std = @import("std");
const core = @import("telar-core");
const control = @import("control.zig");

/// Writes only used conversation data, never backing buffers. Example: `try agent_output.thread(writer, snapshot, true);`
pub fn thread(writer: *std.Io.Writer, snapshot: *const core.AgentThreadSnapshot, json: bool) !void {
    if (json) {
        try writer.print("{{\"pane_id\":{d},\"pane_generation\":{d},\"revision\":{d},\"thread_id\":", .{ core.raw(snapshot.pane_id), snapshot.pane_generation, snapshot.revision });
        try control.writeJsonString(writer, snapshot.threadId());
        try writer.writeAll(",\"turn_id\":");
        try control.writeJsonString(writer, snapshot.currentTurnId());
        try writer.writeAll(",\"status\":");
        try control.writeJsonString(writer, @tagName(snapshot.status));
        try writer.print(",\"truncated\":{},\"items\":[", .{snapshot.truncated});
    }

    for (snapshot.items(), 0..) |item, index| {
        if (json) {
            if (index != 0) {
                try writer.writeByte(',');
            }

            try std.json.Stringify.value(.{
                .id = item.identity,
                .turn_id = item.turn_identity,
                .parent_id = item.parent_identity,
                .role = item.role,
                .kind = item.kind,
                .status = item.status,
                .phase = item.phase,
                .text = item.text(snapshot),
                .title = item.title(snapshot),
                .detail = item.detail(snapshot),
                .reference = item.reference(snapshot),
                .source_id = item.sourceId(snapshot),
                .source_turn = item.sourceTurn(snapshot),
                .fragment_offset = item.fragment_offset,
                .fragment_start = item.fragment_start,
                .fragment_end = item.fragment_end,
                .complete = item.complete,
            }, .{}, writer);
        } else {
            try writer.print("[{s}/{s}/{s}] {s}\n", .{ @tagName(item.role), @tagName(item.kind), @tagName(item.status), item.text(snapshot) });
        }
    }

    if (json) {
        try writer.writeAll("],\"pending_approval\":");
        if (snapshot.pending_approval) |*approval| {
            try std.json.Stringify.value(.{ .id = approval.id, .kind = approval.kind, .description = approval.text() }, .{}, writer);
        } else {
            try writer.writeAll("null");
        }

        try writer.writeAll("}\n");
    } else if (snapshot.truncated) {
        try writer.writeAll("[Earlier content omitted.]\n");
    }
}
