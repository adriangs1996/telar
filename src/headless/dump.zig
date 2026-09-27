//! The headless client's exit dump: what a window would have shown when the
//! client left, as one JSON document. It reads the client model once, after
//! the measured work.
const data = @import("model");
const std = @import("std");

/// Writes the tabs, the active tab's panes with their visible rows, the
/// workspace list, the notifications and the link.
///
/// ```zig
/// try dump.write(writer, &client.model);
/// ```
pub fn write(writer: *std.Io.Writer, model: *const data.ClientModel) !void {
    try writer.print("{{\"link\":\"{s}\",\"tabs\":[", .{@tagName(model.runtime_link.phase)});
    const active = model.tabs.activeSlot();
    for (0..model.tabs.count) |slot| {
        if (slot != 0) {
            try writer.writeByte(',');
        }

        try writer.print("{{\"id\":{d},\"active\":{},\"label\":", .{
            @intFromEnum(model.tabs.location[slot].tab_id),
            active == slot,
        });
        try std.json.Stringify.value(data.tab_label.text(model, slot), .{}, writer);
        try writer.writeByte('}');
    }

    try writer.writeAll("],\"panes\":[");
    if (active) |slot| {
        try writePanes(writer, model, slot);
    }

    try writer.writeAll("],\"workspaces\":[");
    const workspaces = &model.workspace_list_snapshot;
    for (0..workspaces.count) |index| {
        if (index != 0) {
            try writer.writeByte(',');
        }

        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(workspaces.nameAt(index), .{}, writer);
        try writer.writeAll(",\"path\":");
        try std.json.Stringify.value(workspaces.pathAt(index), .{}, writer);
        try writer.print(",\"tabs\":{d}}}", .{workspaces.tabCountAt(index)});
    }

    try writer.writeAll("],\"notifications\":[");
    var shown: usize = 0;
    var index: usize = 0;
    while (model.notification_center.itemAt(index)) |item| : (index += 1) {
        if (shown != 0) {
            try writer.writeByte(',');
        }

        try writer.writeAll("{\"title\":");
        try std.json.Stringify.value(item.title(), .{}, writer);
        try writer.writeAll(",\"message\":");
        try std.json.Stringify.value(item.message(), .{}, writer);
        try writer.writeByte('}');
        shown += 1;
    }

    try writer.writeAll("]}\n");
}

fn writePanes(writer: *std.Io.Writer, model: *const data.ClientModel, slot: usize) !void {
    const tab_id = model.tabs.location[slot].tab_id;
    const focused = model.tabs.layout[slot].focused();
    var panes = model.panes.iterateConst(tab_id);
    var first = true;
    while (panes.next()) |pane| {
        if (!first) {
            try writer.writeByte(',');
        }

        first = false;
        const buffer = &pane.buffer;
        try writer.print("{{\"id\":{d},\"focused\":{},\"attached\":{},\"cols\":{d},\"rows\":{d},\"lines\":[", .{
            @intFromEnum(pane.id),
            focused == pane.id,
            pane.attached,
            buffer.w,
            buffer.h,
        });
        for (0..buffer.h) |row| {
            if (row != 0) {
                try writer.writeByte(',');
            }

            try writeRow(writer, buffer.cells[row * buffer.w ..][0..buffer.w]);
        }

        try writer.writeAll("]}");
    }
}

// One row as a JSON string, without its trailing blanks; the second half
// of a wide character adds nothing.
fn writeRow(writer: *std.Io.Writer, cells: anytype) !void {
    var end = cells.len;
    while (end > 0 and std.mem.eql(u8, cells[end - 1].text(), " ")) {
        end -= 1;
    }

    var line: [4096]u8 = undefined;
    var len: usize = 0;
    for (cells[0..end]) |*cell| {
        if (cell.width == 0) {
            continue;
        }

        const text = cell.text();
        if (len + text.len > line.len) {
            break;
        }

        @memcpy(line[len..][0..text.len], text);
        len += text.len;
    }

    try std.json.Stringify.value(line[0..len], .{}, writer);
}
