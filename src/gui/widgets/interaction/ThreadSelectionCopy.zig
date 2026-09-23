//! Copies rendered text from the pinned page window, including offscreen spans.
const ThreadDetails = @import("../ThreadDetails.zig");
const std = @import("std");
const Copy = @This();
const GuiClient = @import("../../GuiClient.zig");
const Position = @import("ThreadTextPosition.zig");
const Row = @import("ThreadTextRow.zig");
gui: *GuiClient,
range: [2]Position,
writer: *std.Io.Writer,

/// Fails before any host write if the selection exceeds its bounded buffer.
/// Example: `try (Copy{ .gui = gui, .range = range, .writer = writer }).write();`
pub fn write(self: Copy) !void {
    const store = self.gui.widgets.thread_text orelse return error.StaleSelection;
    const geometry = store.maps.presented();
    if (geometry.saturated) {
        return error.SelectionGeometryLimit;
    }
    var matched = false;
    for (geometry.rows[0..geometry.row_count]) |row| {
        if (row.owner.pane_id != self.range[0].owner.pane_id or row.order < self.range[0].order or row.order > self.range[1].order) {
            continue;
        }
        const pane = self.gui.app.model.agentPane(row.owner.pane_id) orelse return error.StaleSelection;
        const snapshot = pane.threadItemSource(row.owner.item_identity) orelse return error.StaleSelection;
        if (pane.attachment_generation != row.owner.attachment_generation or snapshot.revision != row.owner.snapshot_revision or snapshot.pane_generation != row.owner.pane_generation) {
            return error.StaleSelection;
        }
        const item = snapshot.findItem(row.owner.item_identity) orelse return error.StaleSelection;
        const before = self.writer.end;
        if (row.detail_len > 0) {
            var owner = row.owner;
            owner.section = .metadata;
            owner.source_offset = row.detail_offset;
            var lines = std.mem.tokenizeAny(u8, item.detail(snapshot), "\r\n");
            while (lines.next()) |line| {
                if (ThreadDetails.represented(line, item.text(snapshot), item.kind == .command)) {
                    continue;
                }
                owner.source_offset = row.detail_offset + @as(u32, @intCast(@intFromPtr(line.ptr) - @intFromPtr(item.detail(snapshot).ptr)));
                try self.section(.{ .row = row, .owner = owner, .text = line });
            }
        }
        if (row.body_len > 0) {
            try self.section(.{ .row = row, .owner = row.owner, .text = item.text(snapshot), .markdown = row.markdown, .code = row.code });
        }
        matched = matched or self.writer.end != before;
    }
    if (!matched) {
        return error.StaleSelection;
    }
}

fn section(self: Copy, value: Section) !void {
    const first: Position = .{ .owner = value.owner, .order = value.row.order, .offset = value.owner.source_offset };
    var last = first;
    last.offset += @intCast(value.text.len);
    if (!self.range[0].before(last) or !first.before(self.range[1])) {
        return;
    }
    const start = if (first.before(self.range[0])) self.range[0].offset - value.owner.source_offset else 0;
    const end = if (self.range[1].before(last)) self.range[1].offset - value.owner.source_offset else @as(u32, @intCast(value.text.len));
    const before = self.writer.end;
    if (before > 0) {
        try self.writer.writeAll("\n\n");
    }
    const content = self.writer.end;
    try (MessageSelectionText{ .text = value.text, .markdown = value.markdown, .code = value.code, .range = .{ start, end } }).write(self.writer);
    if (self.writer.end == content) {
        self.writer.end = before;
    }
}

const Section = @import("ThreadSelectionSection.zig");
const MessageSelectionText = @import("../MessageSelectionText.zig");
