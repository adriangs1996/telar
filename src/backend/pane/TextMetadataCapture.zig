//! Captures links before blit consumes dirty flags or the VT can move its pages.
const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const HyperlinkIndex = @import("HyperlinkIndex.zig");
const TextMetadataCapture = @This();

current: core.TextMetadata,
scratch: core.TextMetadata,
cols: u16 = 0,
revision: u64 = 1,

pub fn init(allocator: std.mem.Allocator, rows: u16) !TextMetadataCapture {
    var current = try core.TextMetadata.init(allocator, rows);
    errdefer current.deinit(allocator);
    return .{ .current = current, .scratch = try core.TextMetadata.init(allocator, rows) };
}

pub fn deinit(capture: *TextMetadataCapture, allocator: std.mem.Allocator) void {
    capture.current.deinit(allocator);
    capture.scratch.deinit(allocator);
}

/// The state must have just been updated while its terminal is exclusively borrowed.
/// Example: `try capture.update(allocator, &render_state);`
pub fn update(capture: *TextMetadataCapture, allocator: std.mem.Allocator, state: *const vt.RenderState) !void {
    try capture.current.reserve(allocator, state.rows);
    try capture.scratch.reserve(allocator, state.rows);
    const previous = capture.current.view();
    const rows = state.row_data.slice();
    const raw_rows = rows.items(.raw);
    const dirty = rows.items(.dirty);
    const resized = previous.rows.len != state.rows or capture.cols != state.cols;
    var rebuild = resized or state.dirty == .full;
    var changed = rebuild;
    for (0..state.rows) |y| {
        const flags = rowFlags(state, y);
        if (resized or @as(u8, @bitCast(flags)) != @as(u8, @bitCast(previous.rows[y]))) {
            changed = true;
        }

        if (dirty[y] and (raw_rows[y].hyperlink or (!resized and previous.rows[y].hyperlinks))) {
            rebuild = true;
        }
    }

    if (!rebuild and !changed) {
        return;
    }

    const next = if (rebuild) capture.collect(state) else flags_only: {
        capture.scratch.replace(previous);
        for (0..state.rows) |y| {
            capture.scratch.buffer[core.text_metadata_limits.header_size + y] = @bitCast(rowFlags(state, y));
        }

        break :flags_only capture.scratch.view();
    };
    capture.cols = state.cols;
    if (std.mem.eql(u8, previous.encoded, next.encoded)) {
        return;
    }

    capture.current.replace(next);
    capture.revision +%= 1;
    if (capture.revision == 0) {
        capture.revision = 1;
    }
}

fn collect(capture: *TextMetadataCapture, state: *const vt.RenderState) core.TextMetadataView {
    var builder = core.TextMetadataBuilder.init(capture.scratch.buffer, state.rows);
    for (0..state.rows) |y| {
        builder.setRow(@intCast(y), rowFlags(state, y));
    }

    collectLinks(&builder, state) catch return builder.finish(.omitted);
    return builder.finish(.complete);
}

fn collectLinks(builder: *core.TextMetadataBuilder, state: *const vt.RenderState) !void {
    var identities: HyperlinkIndex = .{};
    const rows = state.row_data.slice();
    for (rows.items(.raw), rows.items(.pin), rows.items(.cells), 0..) |row, pin, cells, y| {
        if (!row.hyperlink) {
            continue;
        }

        const page = pin.node.page();
        var pending: ?core.TextLinkRun = null;
        for (cells.items(.raw), 0..) |cell, x| {
            const link_index = if (cell.hyperlink and cell.wide != .spacer_head) found: {
                const live = page.getRowAndCell(x, pin.y).cell;
                const id = page.lookupHyperlink(live) orelse break :found null;
                break :found try identities.intern(builder, .{ .page = page, .id = id });
            } else null;
            const start: u32 = @intCast(y * state.cols + x);
            if (pending) |*run| {
                if (link_index != null and link_index.? == run.link_index and start == run.start + run.len) {
                    run.len += 1;
                    continue;
                }

                try builder.addRun(run.*);
                pending = null;
            }

            if (link_index) |index| {
                pending = .{ .start = start, .len = 1, .link_index = index };
            }
        }

        if (pending) |run| {
            try builder.addRun(run);
        }
    }
}

fn rowFlags(state: *const vt.RenderState, y: usize) core.TextRowFlags {
    const rows = state.row_data.slice();
    const row = rows.items(.raw)[y];
    const cells = rows.items(.cells)[y].items(.raw);
    return .{
        .wrap = row.wrap,
        .continuation = row.wrap_continuation,
        .wide_padding = row.wrap and cells.len != 0 and cells[cells.len - 1].wide == .spacer_head,
        .hyperlinks = row.hyperlink,
    };
}

test "text metadata preserves explicit OSC 8 identity and wide-cell runs" {
    const BlitPane = @import("BlitPane.zig");
    var pane = try BlitPane.init(std.testing.allocator, 24, 4);
    defer pane.deinit();
    var capture = try TextMetadataCapture.init(std.testing.allocator, 4);
    defer capture.deinit(std.testing.allocator);
    try pane.write("\x1b]8;id=first;https://example.com\x1b\\界ab\x1b]8;;\x1b\\ \x1b]8;id=second;https://example.com\x1b\\cd\x1b]8;;\x1b\\\r\n\x1b]8;id=first;https://example.com\x1b\\ef\x1b]8;;\x1b\\");
    try capture.update(std.testing.allocator, &pane.state);
    const view = capture.current.view();
    _ = try core.TextMetadataView.decode(view.encoded, .{ 24, 4 });
    try std.testing.expectEqual(@as(u16, 2), view.link_count);
    try std.testing.expectEqual(@as(u16, 3), view.run_count);
    try std.testing.expectEqualStrings("https://example.com", view.link(0).?);
    try std.testing.expectEqualDeep(core.TextLinkRun{ .start = 0, .len = 4, .link_index = 0 }, view.at(1).?);
    try std.testing.expectEqual(@as(u16, 1), view.at(5).?.link_index);
    try std.testing.expectEqual(@as(u16, 0), view.at(24).?.link_index);
}

test "text metadata captures soft wrap and wide padding before blit clears damage" {
    const BlitPane = @import("BlitPane.zig");
    var pane = try BlitPane.init(std.testing.allocator, 12, 4);
    defer pane.deinit();
    var capture = try TextMetadataCapture.init(std.testing.allocator, 4);
    defer capture.deinit(std.testing.allocator);
    try pane.write("https://e/a界b\r\nhard line");
    try capture.update(std.testing.allocator, &pane.state);
    const view = capture.current.view();
    try std.testing.expect(view.rows[0].wrap);
    try std.testing.expect(view.rows[0].wide_padding);
    try std.testing.expect(view.rows[1].continuation);
    try std.testing.expect(!view.rows[1].wrap);
    try std.testing.expect(!view.rows[2].continuation);
    var buffer = try core.Buffer.init(std.testing.allocator, 12, 4);
    defer buffer.deinit();
    _ = @import("blit.zig").blit(.{ .buffer = &buffer, .area = buffer.area(), .terminal = &pane.term, .state = &pane.state, .options = .{} });
    try std.testing.expectEqual(.false, pane.state.dirty);
    const revision = capture.revision;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try capture.update(failing.allocator(), &pane.state);
    try std.testing.expectEqual(revision, capture.revision);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "text metadata drops an over-quota URI whole and recovers without allocation" {
    const BlitPane = @import("BlitPane.zig");
    var pane = try BlitPane.init(std.testing.allocator, 20, 3);
    defer pane.deinit();
    var capture = try TextMetadataCapture.init(std.testing.allocator, 3);
    defer capture.deinit(std.testing.allocator);
    try pane.term.screens.active.startHyperlink("https://e/" ++ "a" ** 4096, null);
    try pane.write("label");
    pane.term.screens.active.endHyperlink();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try capture.update(failing.allocator(), &pane.state);
    const omitted = capture.current.view();
    try std.testing.expectEqual(.omitted, omitted.status);
    try std.testing.expectEqual(@as(u16, 0), omitted.link_count);
    try std.testing.expectEqual(@as(u16, 0), omitted.run_count);
    try std.testing.expect(omitted.rows[0].hyperlinks);
    try pane.write("\x1b[H\x1b[2J\x1b]8;;https://ok.example\x1b\\label\x1b]8;;\x1b\\");
    try capture.update(failing.allocator(), &pane.state);
    try std.testing.expectEqual(.complete, capture.current.view().status);
    try std.testing.expectEqualStrings("https://ok.example", capture.current.view().link(0).?);
    const revision = capture.revision;
    for (0..120) |_| {
        try capture.update(failing.allocator(), &pane.state);
        try std.testing.expectEqual(revision, capture.revision);
    }

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}
