//! Bounded geometry and source catalog published with the frame that drew it.
const std = @import("std");
const core = @import("telar-core");
const Geometry = @This();
const Row = @import("ThreadTextRow.zig");
const Fragment = @import("ThreadTextFragment.zig");
const Caret = @import("ThreadTextCaret.zig");
const Position = @import("ThreadTextPosition.zig");
const Run = @import("ThreadTextRun.zig");
const Canvas = @import("../Canvas.zig");

pub const max_rows = 16 * 128;
pub const max_fragments = 4096;
pub const max_carets = 32768;
rows: [max_rows]Row = undefined,
row_count: u16 = 0,
fragments: [max_fragments]Fragment = undefined,
fragment_count: u16 = 0,
carets: [max_carets]Caret = undefined,
caret_count: u16 = 0,
saturated: bool = false,

/// Example: `geometry.addRow(view, order);`
pub fn addRow(geometry: *Geometry, view: @import("../ThreadItemView.zig"), order: u16) void {
    if (geometry.row_count == max_rows) {
        geometry.saturated = true;
        return;
    }
    const kind = view.item.kind;
    const message = kind == .message and (view.item.role == .assistant or view.item.role == .user);
    const notice = kind == .system or (kind == .message and view.item.role == .system);
    const body_visible = message or notice or view.expanded;
    geometry.rows[geometry.row_count] = .{ .owner = view.source(.body), .order = order, .body_len = if (body_visible) view.item.text_len else 0, .detail_offset = view.item.detail_offset, .detail_len = if (!message and !notice and view.expanded) view.item.detail_len else 0, .markdown = !notice and view.item.role != .user and view.item.fragment_start and view.item.fragment_end, .code = kind == .command or kind == .file_change or kind == .mcp or kind == .dynamic_tool };
    geometry.row_count += 1;
}

/// Captures exact grapheme carets from the font that paints the fragment.
/// Example: `const fragment = try geometry.append(canvas, run);`
pub fn append(geometry: *Geometry, canvas: *Canvas, run: Run) !?Fragment {
    if (run.text.len == 0 or run.text.len > std.math.maxInt(u16)) {
        return null;
    }
    const row = geometry.findRow(run.owner) orelse return null;
    if (geometry.fragment_count == max_fragments) {
        geometry.saturated = true;
        return null;
    }
    var count: usize = 1;
    var iterator: core.GraphemeIterator = .{ .bytes = run.text };
    while (iterator.next() != null) {
        count += 1;
    }
    if ((run.face == .sans and run.text.len > 256 and count > 2) or count > max_carets - geometry.caret_count) {
        geometry.saturated = true;
        return null;
    }
    const start = geometry.caret_count;
    geometry.carets[start] = .{ .offset = 0, .x = 0 };
    geometry.caret_count += 1;
    var positions: [257]u32 = undefined;
    const shaped = run.face == .sans and run.text.len <= 256;
    if (shaped) {
        try canvas.atlas.caretPositions(.{ .text = run.text, .x = 0, .y = 0, .color = .white, .pixel_height = run.pixel_height, .face = if (run.bold) .sans_semibold else .sans }, positions[0 .. run.text.len + 1]);
    }
    iterator = .{ .bytes = run.text };
    var width: f32 = 0;
    while (iterator.next()) |cluster| {
        width = if (shaped) @floatFromInt(positions[iterator.index]) else if (run.face == .sans) run.advance else width + @as(f32, @floatFromInt(cluster.width * canvas.metrics.cell_width));
        geometry.carets[geometry.caret_count] = .{ .offset = @intCast(iterator.index), .x = width };
        geometry.caret_count += 1;
    }
    const fragment: Fragment = .{ .row = row, .section = run.owner.section, .offset = run.offset, .len = @intCast(run.text.len), .bounds = run.bounds, .clip = run.viewport, .caret_start = start, .caret_count = @intCast(count) };
    geometry.fragments[geometry.fragment_count] = fragment;
    geometry.fragment_count += 1;
    return fragment;
}

/// Resolves source ownership without retaining the source buffer.
/// Example: `const row = geometry.findRow(owner) orelse return;`
pub fn findRow(geometry: *const Geometry, owner: @import("../MessageLayoutOwner.zig")) ?u16 {
    for (geometry.rows[0..geometry.row_count], 0..) |row, index| {
        const value = row.owner;
        if (value.pane_id == owner.pane_id and value.attachment_generation == owner.attachment_generation and value.pane_generation == owner.pane_generation and value.snapshot_revision == owner.snapshot_revision and value.item_identity == owner.item_identity) {
            return @intCast(index);
        }
    }
    return null;
}

/// Example: `const caret = geometry.position(fragment, index);`
pub fn position(geometry: *const Geometry, fragment: Fragment, index: usize) Position {
    const row = geometry.rows[fragment.row];
    var owner = row.owner;
    owner.section = fragment.section;
    owner.source_offset = if (owner.section == .metadata) row.detail_offset else row.owner.source_offset;
    return .{ .owner = owner, .order = row.order, .offset = fragment.offset + geometry.carets[fragment.caret_start + index].offset };
}

/// Finds the nearest delivered text caret, including whitespace between words.
/// Example: `const position = geometry.hit(.{ .pane_id = id, .point = point });`
pub fn hit(geometry: *const Geometry, query: Hit) ?Position {
    var found: ?Position = null;
    var distance = std.math.inf(f64);
    for (geometry.fragments[0..geometry.fragment_count]) |fragment| {
        const row = geometry.rows[fragment.row];
        if (row.owner.pane_id != query.pane_id) {
            continue;
        }
        const top = @max(fragment.bounds.y, fragment.clip.y);
        const bottom = @min(fragment.bounds.y + fragment.bounds.height, fragment.clip.y + fragment.clip.height);
        if (bottom <= top) {
            continue;
        }
        const dy = if (query.point[1] < top) top - query.point[1] else if (query.point[1] >= bottom) query.point[1] - bottom + 1 else 0;
        for (geometry.carets[fragment.caret_start..][0..fragment.caret_count], 0..) |caret, index| {
            const x = fragment.bounds.x + caret.x;
            if (x < @max(fragment.bounds.x, fragment.clip.x) or x > @min(fragment.bounds.x + fragment.bounds.width, fragment.clip.x + fragment.clip.width)) {
                continue;
            }
            const score = dy * 100000 + @abs(query.point[0] - x);
            if (score < distance) {
                distance = score;
                found = geometry.position(fragment, index);
            }
        }
    }
    return found;
}

const Hit = @import("ThreadTextHit.zig");
