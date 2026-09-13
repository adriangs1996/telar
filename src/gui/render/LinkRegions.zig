//! Borrows one pane while enumerating the visible spans of its hovered link.
const core = @import("telar-core");
const client = @import("telar-client");
const Hit = @import("../input/LinkHit.zig");
const Regions = @This();

hit: *const Hit,
pane: *const client.Pane,
metadata: core.TextMetadataView,
runs: core.TextLinkRuns,
row: u32,

/// OSC 8 highlights every run of an identity; plain URLs follow soft wraps.
/// Example: `var regions = Regions.init(hit, pane);`
pub fn init(hit: *const Hit, pane: *const client.Pane) Regions {
    const metadata = pane.text_metadata.view();
    return .{ .hit = hit, .pane = pane, .metadata = metadata, .runs = metadata.runs(), .row = @max(hit.scroll_offset, hit.match.start.y) };
}

/// Returns clipped host-grid rectangles without allocating or retaining a view.
/// Example: `while (regions.next()) |area| try underline(area);`
pub fn next(regions: *Regions) ?core.Rect {
    if (regions.hit.match.link_index) |link_index| {
        while (regions.runs.next()) |run| {
            if (run.link_index != link_index) {
                continue;
            }

            const row = run.start / regions.pane.buffer.w;
            const x: u16 = @intCast(run.start % regions.pane.buffer.w);
            if (regions.clippedArea(row, .{ x, @intCast(@as(u32, x) + run.len) })) |area| {
                return area;
            }
        }

        return null;
    }

    const hit = regions.hit;
    while (regions.row <= hit.match.end.y and regions.row - hit.scroll_offset < hit.content.h) {
        const row = regions.row;
        regions.row += 1;
        const y = row - hit.scroll_offset;
        var right = if (row == hit.match.end.y) hit.match.end.x else regions.pane.buffer.w;
        if (y < regions.metadata.rows.len and regions.metadata.rows[y].wide_padding) {
            right = @min(right, regions.pane.buffer.w -| 1);
        }

        if (regions.clippedArea(y, .{ if (row == hit.match.start.y) hit.match.start.x else 0, right })) |area| {
            return area;
        }
    }

    return null;
}

fn clippedArea(regions: *const Regions, row: u32, columns: [2]u16) ?core.Rect {
    const content = regions.hit.content;
    const right = @min(columns[1], content.w);
    if (row >= content.h or columns[0] >= right) {
        return null;
    }

    return .{ .x = content.x + columns[0], .y = content.y + @as(u16, @intCast(row)), .w = right - columns[0], .h = 1 };
}
