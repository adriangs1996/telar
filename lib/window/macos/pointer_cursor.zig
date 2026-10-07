const std = @import("std");
const objc = @import("objc");

// Values match the semantic pointer shape contract; this platform library does
// not import application core. Unsupported native shapes use the documented fallbacks.
const Shape = enum(u32) {
    default = 0,
    context_menu = 1,
    help = 2,
    pointer = 3,
    progress = 4,
    wait = 5,
    cell = 6,
    crosshair = 7,
    text = 8,
    vertical_text = 9,
    alias = 10,
    copy = 11,
    move = 12,
    no_drop = 13,
    not_allowed = 14,
    grab = 15,
    grabbing = 16,
    all_scroll = 17,
    col_resize = 18,
    row_resize = 19,
    n_resize = 20,
    e_resize = 21,
    s_resize = 22,
    w_resize = 23,
    ne_resize = 24,
    nw_resize = 25,
    se_resize = 26,
    sw_resize = 27,
    ew_resize = 28,
    ns_resize = 29,
    nesw_resize = 30,
    nwse_resize = 31,
    zoom_in = 32,
    zoom_out = 33,
};
const Horizontal = enum(usize) { left = 1, right = 2 };
const Vertical = enum(usize) { up = 1, down = 2 };
const Position = enum(usize) { top = 1, top_left = 3, bottom_left = 6, right = 8, top_right = 9, bottom_right = 12 };
const Directions = enum(usize) { all = 3 };
const count = @typeInfo(Shape).@"enum".fields.len;
var cursors: [count]?objc.Object = @splat(null);

/// The window's setter calls this on the main thread. Retain the bounded set
/// once for process lifetime, so event-time autorelease pools cannot invalidate it.
pub fn get(raw: u32) objc.Object {
    const shape = std.enums.fromInt(Shape, raw) orelse .default;
    if (cursors[0] == null) {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        for (&cursors, 0..) |*cursor, index| {
            cursor.* = create(@enumFromInt(index)).retain();
        }
    }

    return cursors[@intFromEnum(shape)].?;
}

fn create(shape: Shape) objc.Object {
    const class = objc.getClass("NSCursor").?;
    return switch (shape) {
        // AppKit has no distinct help, progress or wait cursor.
        .default, .help, .progress, .wait => class.msgSend(objc.Object, "arrowCursor", .{}),
        .context_menu => class.msgSend(objc.Object, "contextualMenuCursor", .{}),
        .pointer => class.msgSend(objc.Object, "pointingHandCursor", .{}),
        .cell, .crosshair => class.msgSend(objc.Object, "crosshairCursor", .{}),
        .text => class.msgSend(objc.Object, "IBeamCursor", .{}),
        .vertical_text => class.msgSend(objc.Object, "IBeamCursorForVerticalLayout", .{}),
        .alias => class.msgSend(objc.Object, "dragLinkCursor", .{}),
        .copy => class.msgSend(objc.Object, "dragCopyCursor", .{}),
        .move, .grab, .all_scroll => class.msgSend(objc.Object, "openHandCursor", .{}),
        .no_drop, .not_allowed => class.msgSend(objc.Object, "operationNotAllowedCursor", .{}),
        .grabbing => class.msgSend(objc.Object, "closedHandCursor", .{}),
        .col_resize => class.msgSend(objc.Object, "columnResizeCursor", .{}),
        .row_resize => class.msgSend(objc.Object, "rowResizeCursor", .{}),
        .n_resize => class.msgSend(objc.Object, "rowResizeCursorInDirections:", .{@intFromEnum(Vertical.up)}),
        .s_resize => class.msgSend(objc.Object, "rowResizeCursorInDirections:", .{@intFromEnum(Vertical.down)}),
        .e_resize => class.msgSend(objc.Object, "columnResizeCursorInDirections:", .{@intFromEnum(Horizontal.right)}),
        .w_resize => class.msgSend(objc.Object, "columnResizeCursorInDirections:", .{@intFromEnum(Horizontal.left)}),
        .ne_resize, .nesw_resize => frame(class, .top_right),
        .nw_resize, .nwse_resize => frame(class, .top_left),
        .se_resize => frame(class, .bottom_right),
        .sw_resize => frame(class, .bottom_left),
        .ew_resize => frame(class, .right),
        .ns_resize => frame(class, .top),
        .zoom_in => class.msgSend(objc.Object, "zoomInCursor", .{}),
        .zoom_out => class.msgSend(objc.Object, "zoomOutCursor", .{}),
    };
}

fn frame(class: objc.Class, position: Position) objc.Object {
    return class.msgSend(objc.Object, "frameResizeCursorFromPosition:inDirections:", .{ @intFromEnum(position), @intFromEnum(Directions.all) });
}
