//! Where the path picker sits: under the focused pane's cursor, or above it
//! when the rows below do not fit, with the search field always on the
//! edge next to the cursor. Both adapters place it with the same cells.

const cellgrid = @import("cellgrid");
const std = @import("std");
const ClientModel = @import("ClientModel.zig");
const LayoutSnapshot = @import("../workspace/LayoutSnapshot.zig");
const PathPickerPlacement = @import("PathPickerPlacement.zig");
const tab_layout = @import("../workspace/tab_layout.zig");

/// Matches the picker shows at once.
pub const max_rows = 10;
/// Columns the picker wants before the host clips it.
pub const max_width = 72;
/// The border, the field row and the hint row around the matches.
const chrome_rows = 4;
/// Columns left of the cursor, so the field's text starts near it.
const cursor_inset = 2;

/// Places the picker for a page of `len` matches.
///
/// ```zig
/// const placement = path_picker_placement.forPage(host, cursor, state.len);
/// ```
pub fn forPage(host: cellgrid.Rect, cursor: ?cellgrid.Point, len: u16) PathPickerPlacement {
    const rows: u16 = @max(@min(len, max_rows), 1);
    return place(host, cursor, max_width, rows + chrome_rows);
}

/// Where the picker sits on the host grid now, from the model's cached
/// layout of the active tab; null before that tab was laid out. Input reads
/// it to move the selection the way the rows run on screen.
///
/// ```zig
/// const flipped = if (path_picker_placement.current(model)) |placement| placement.flipped else false;
/// ```
pub fn current(model: *const ClientModel) ?PathPickerPlacement {
    const tab = model.tabs.activeSlot() orelse return null;
    if (model.layout_snapshot_tab != model.tabs.location[tab].tab_id) {
        return null;
    }

    const size = model.host.host_size;
    const host: cellgrid.Rect = .{
        .w = size.cols,
        .h = size.rows,
    };
    return forPage(host, cursorCell(model, tab, &model.layout_snapshot), model.path_picker.len);
}

/// The focused pane's cursor in host cells, or null when it is not on
/// screen. Example: `const cursor = path_picker_placement.cursorCell(model, tab, layout);`
pub fn cursorCell(model: *const ClientModel, tab: usize, layout: *const LayoutSnapshot) ?cellgrid.Point {
    const pane = tab_layout.focusedPaneConst(model, tab) orelse return null;
    const view = layout.find(pane.id) orelse return null;
    if (pane.cursor.x >= view.content.w or pane.cursor.y >= view.content.h) {
        return null;
    }

    return .{
        .x = view.content.x + pane.cursor.x,
        .y = view.content.y + pane.cursor.y,
    };
}

/// Places a `width` by `height` picker inside `host` next to `cursor`;
/// without a cursor it sits centred a third of the way down.
///
/// ```zig
/// const placement = path_picker_placement.place(host, cursor, 72, 14);
/// ```
pub fn place(host: cellgrid.Rect, cursor: ?cellgrid.Point, width: u16, height: u16) PathPickerPlacement {
    const w = @min(width, host.w);
    const h = @min(height, host.h);
    const at = cursor orelse return .{
        .area = .{
            .x = host.x + (host.w - w) / 2,
            .y = host.y + (host.h - h) / 3,
            .w = w,
            .h = h,
        },
        .flipped = false,
    };

    const x = @min(at.x -| cursor_inset, host.x + host.w - w);
    const below = host.y + host.h -| (at.y + 1);
    const above = at.y -| host.y;
    const flipped = below < h and above > below;
    const room = if (flipped) above else below;
    const fitted = @min(h, room);
    return .{
        .area = .{
            .x = @max(x, host.x),
            .y = if (flipped) at.y - fitted else at.y + 1,
            .w = w,
            .h = fitted,
        },
        .flipped = flipped,
    };
}

test "the picker opens under the cursor and flips above it near the bottom" {
    const host: cellgrid.Rect = .{
        .w = 100,
        .h = 40,
    };
    const under = place(
        host,
        .{
            .x = 10,
            .y = 5,
        },
        60,
        14,
    );
    try std.testing.expect(!under.flipped);
    try std.testing.expectEqual(@as(u16, 6), under.area.y);
    try std.testing.expectEqual(@as(u16, 8), under.area.x);

    const over = place(
        host,
        .{
            .x = 90,
            .y = 38,
        },
        60,
        14,
    );
    try std.testing.expect(over.flipped);
    try std.testing.expectEqual(@as(u16, 38 - 14), over.area.y);
    try std.testing.expectEqual(@as(u16, 40), over.area.x);

    const centred = place(
        host,
        null,
        60,
        14,
    );
    try std.testing.expectEqual(@as(u16, 20), centred.area.x);

    const tiny = place(
        .{
            .w = 20,
            .h = 6,
        },
        .{
            .x = 1,
            .y = 2,
        },
        60,
        14,
    );
    try std.testing.expect(tiny.area.w <= 20 and tiny.area.y + tiny.area.h <= 6);
}
