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

/// Writes the live provider catalog and selection. Example: `try agent_output.models(writer, snapshot, true);`
pub fn models(writer: *std.Io.Writer, snapshot: *const core.AgentThreadSnapshot, json: bool) !void {
    if (json) {
        try writer.writeAll("{\"selected\":");
        try std.json.Stringify.value(.{ .model = snapshot.options.modelSlice(), .effort = snapshot.options.effort.idSlice(), .access = snapshot.options.access }, .{}, writer);
        try writer.writeAll(",\"models\":[");
    }

    for (snapshot.models(), 0..) |*model, index| {
        if (json) {
            if (index != 0) {
                try writer.writeByte(',');
            }

            try writer.writeAll("{\"id\":");
            try control.writeJsonString(writer, model.idSlice());
            try writer.writeAll(",\"label\":");
            try control.writeJsonString(writer, model.labelSlice());
            try writer.writeAll(",\"default_effort\":");
            try control.writeJsonString(writer, model.default_effort.idSlice());
            try writer.writeAll(",\"efforts\":[");
            for (model.efforts(), 0..) |effort, effort_index| {
                if (effort_index != 0) {
                    try writer.writeByte(',');
                }

                try control.writeJsonString(writer, effort.idSlice());
            }

            try writer.writeAll("]}");
        } else {
            try writer.print("{s}\t{s}\tdefault effort: {s}\n", .{ model.idSlice(), model.labelSlice(), model.default_effort.idSlice() });
        }
    }

    if (json) {
        try writer.writeAll("]}\n");
    }
}

/// Preserves loading, failure and truncation states. Example: `try agent_output.skills(writer, snapshot, true);`
pub fn skills(writer: *std.Io.Writer, snapshot: *const core.AgentThreadSnapshot, json: bool) !void {
    const catalog = &snapshot.skills;
    if (json) {
        try writer.print("{{\"revision\":{d},\"phase\":\"{s}\",\"truncated\":{},\"skills\":[", .{ catalog.revision, @tagName(catalog.phase), catalog.truncated });
    } else {
        try writer.print("{s}{s}\n", .{ @tagName(catalog.phase), if (catalog.truncated) " (truncated)" else "" });
    }

    for (catalog.entries[0..catalog.count], 0..) |skill, index| {
        if (json) {
            if (index != 0) {
                try writer.writeByte(',');
            }

            try std.json.Stringify.value(.{ .name = skill.name(catalog), .label = skill.label(catalog), .description = skill.description(catalog), .scope = skill.scope }, .{}, writer);
        } else {
            try writer.print("{s}\t{s}\t{s}\n", .{ skill.name(catalog), @tagName(skill.scope), skill.description(catalog) });
        }
    }

    if (json) {
        try writer.writeAll("]}\n");
    }
}

/// Lists resumable provider conversations with their stable IDs. Example: `try agent_output.conversations(writer, snapshot, true);`
pub fn conversations(writer: *std.Io.Writer, snapshot: *const core.AgentThreadSnapshot, json: bool) !void {
    const catalog = &snapshot.recent;
    if (json) {
        try writer.print("{{\"phase\":\"{s}\",\"has_more\":{},\"can_resume\":{},\"conversations\":[", .{ @tagName(catalog.phase), catalog.has_more, snapshot.canResume() });
    } else {
        try writer.print("{s}{s}\n", .{ @tagName(catalog.phase), if (catalog.has_more) " (more available)" else "" });
    }

    for (catalog.entries[0..catalog.count], 0..) |*entry, index| {
        if (json) {
            if (index != 0) {
                try writer.writeByte(',');
            }

            try std.json.Stringify.value(.{ .id = entry.idSlice(), .title = entry.titleSlice() }, .{}, writer);
        } else {
            try writer.print("{s}\t{s}\n", .{ entry.idSlice(), entry.titleSlice() });
        }
    }

    if (json) {
        try writer.writeAll("]}\n");
    }
}

/// Shows the exact request identity required for a decision. Example: `try agent_output.approvals(writer, snapshot, true);`
pub fn approvals(writer: *std.Io.Writer, snapshot: *const core.AgentThreadSnapshot, json: bool) !void {
    if (json) {
        try writer.writeByte('[');
    }

    if (snapshot.pending_approval) |*approval| {
        if (json) {
            try std.json.Stringify.value(.{ .id = approval.id, .kind = approval.kind, .description = approval.text() }, .{}, writer);
        } else {
            try writer.print("{d}\t{s}\t{s}\n", .{ approval.id, @tagName(approval.kind), approval.text() });
        }
    }

    if (json) {
        try writer.writeAll("]\n");
    }
}

/// Writes provider pagination separately from the retained live window. Example: `try agent_output.history(writer, page, true);`
pub fn history(writer: *std.Io.Writer, page: *const core.AgentHistoryPage, json: bool) !void {
    if (json) {
        try writer.writeAll("{\"pagination\":");
        try std.json.Stringify.value(.{ .before = page.before.slice(), .after = page.after.slice(), .has_before = page.has_before, .has_after = page.has_after }, .{}, writer);
        try writer.writeAll(",\"thread\":");
    }

    try thread(writer, &page.snapshot, json);
    if (json) {
        try writer.writeAll("}\n");
    } else {
        try writer.print("before: {s} ({})\nafter: {s} ({})\n", .{ page.before.slice(), page.has_before, page.after.slice(), page.has_after });
    }
}
