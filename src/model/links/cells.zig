//! Adapts a pane's cell row to the byte-oriented link recognizer in `urlscan`.
const urlscan = @import("urlscan");
const cellgrid = @import("cellgrid");
const Pane = @import("../panes/Pane.zig");
const core_module = @import("telar-core");
const data = @import("../model.zig");
const Position = @import("Position.zig");
const LinkMatch = @import("LinkMatch.zig");
const LinkGrid = @import("LinkGrid.zig");

/// The longest link the window must hold on either side of the cursor: a
/// Markdown label, its destination and the four delimiters around them.
const link_span_bytes = urlscan.max_uri_bytes + urlscan.max_label_bytes + 4;
const row_window_bytes = link_span_bytes * 2 + cellgrid.Cell.max_bytes * 2;
const max_walk_cells = row_window_bytes * 2;

/// Extracts the textual URI under one absolute pane position without allocating.
///
/// ```zig
/// const target = extract(&buffer, scroll, .{ .x = 3, .y = 10 });
/// ```
pub fn extract(buffer: *const cellgrid.Buffer, scroll: core_module.Scroll, position: Position) ?data.LinkTarget {
    const found = match(buffer, scroll, position) orelse return null;
    return found.target;
}

/// Resolves a URI and its exclusive cell interval in absolute pane coordinates.
/// The row window and the owned target are bounded; no allocation occurs.
/// Example: `const found = match(&buffer, scroll, .{ .x = 3, .y = 10 });`
pub fn match(buffer: *const cellgrid.Buffer, scroll: core_module.Scroll, position: Position) ?LinkMatch {
    return matchGrid(.{ .buffer = buffer, .scroll = scroll }, position);
}

/// Resolves OSC 8 first, then visible URI text across VT-confirmed soft wraps.
/// Example: `const found = resolve(pane, .{ .x = 3, .y = pane.scroll.offset });`
pub fn resolve(pane: *const Pane, position: Position) ?LinkMatch {
    const metadata = pane.text_metadata.view();
    const grid: LinkGrid = .{ .buffer = &pane.buffer, .scroll = pane.scroll, .rows = metadata.rows };
    const index = grid.cellIndex(position) orelse return null;
    if (metadata.at(@intCast(index))) |run| {
        return .{
            .target = data.LinkTarget.init(metadata.link(run.link_index).?) catch return null,
            .start = grid.position(run.start),
            .end = grid.cellEnd(run.start + run.len - 1),
            .link_index = run.link_index,
        };
    }

    // A link the table dropped cannot authorize its label as its own
    // destination.
    if (metadata.status != .complete and metadata.rows[index / pane.buffer.w].hyperlinks) {
        return null;
    }

    return matchGrid(grid, position);
}

fn matchGrid(grid: LinkGrid, position: Position) ?LinkMatch {
    const cursor = grid.cellIndex(position) orelse return null;
    var start = cursor;
    var bytes_before: usize = 0;
    var visited: usize = 0;
    while (bytes_before <= link_span_bytes) {
        if (visited == max_walk_cells) {
            return null;
        }

        visited += 1;
        start = grid.previous(start) orelse break;
        bytes_before += grid.buffer.cells[start].text().len;
    }

    var storage: [row_window_bytes]u8 = undefined;
    var len: usize = 0;
    var cursor_offset: ?usize = null;
    var index = start;
    visited = 0;
    while (true) {
        if (visited == max_walk_cells) {
            return null;
        }

        visited += 1;
        if (index == cursor) {
            cursor_offset = len;
        }

        const text = grid.buffer.cells[index].text();
        if (text.len > storage.len - len) {
            break;
        }

        @memcpy(storage[len..][0..text.len], text);
        len += text.len;
        if (cursor_offset) |offset| {
            if (len - offset >= link_span_bytes + cellgrid.Cell.max_bytes) {
                break;
            }
        }

        index = grid.next(index) orelse break;
    }

    const offset = cursor_offset orelse return null;
    const window = storage[0..len];
    // A Markdown link claims its label and markup too; bare URI text comes
    // next, and a local path such as `src/main.zig:12` is the last resort.
    const span, const destination, const scheme: ?urlscan.Scheme = if (urlscan.markdownLinkAt(window, offset)) |link|
        .{ [2]usize{ link.start, link.end }, link.destinationText(window), null }
    else if (urlscan.extractAt(window, offset)) |found|
        .{ [2]usize{ found.start, found.end }, found.text(window), found.scheme }
    else if (urlscan.pathAt(window, offset)) |found|
        .{ [2]usize{ found.start, found.end }, found.text(window), found.scheme }
    else
        return null;
    const range = positions(grid, start, span) orelse return null;
    if (!completeRange(grid, range)) {
        return null;
    }

    return .{
        .target = (if (scheme == .path) data.LinkTarget.initPath(destination) else data.LinkTarget.init(destination)) catch return null,
        .start = range[0],
        .end = range[1],
    };
}

fn completeRange(grid: LinkGrid, range: [2]Position) bool {
    if (grid.rows.len == 0) {
        return true;
    }

    if (range[0].y == grid.scroll.offset and range[0].x == 0 and grid.rows[0].continuation) {
        return false;
    }

    const last = grid.rows[grid.rows.len - 1];
    const last_text_column = grid.buffer.w - @intFromBool(last.wide_padding);
    return !(range[1].y - grid.scroll.offset == grid.rows.len - 1 and range[1].x == last_text_column and last.wrap);
}

fn positions(grid: LinkGrid, first: usize, span: [2]usize) ?[2]Position {
    var index = first;
    var offset: usize = 0;
    var start: ?Position = null;
    while (true) {
        const cell = &grid.buffer.cells[index];
        const end = offset + cell.text().len;
        if (start == null and offset <= span[0] and end > span[0]) {
            start = grid.position(index);
        }

        if (end >= span[1]) {
            return .{ start orelse return null, grid.cellEnd(index) };
        }

        offset = end;
        index = grid.next(index) orelse return null;
    }
}
