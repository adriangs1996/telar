const GraphicsEffectType = @import("GraphicsEffect.zig");
const PositionType = @import("Position.zig");
const ScreenStats = @import("ScreenStats.zig");
const BufferType = @import("telar-core").Buffer;
const DamageRowType = @import("telar-client").DamageRow;
const std = @import("std");
const PointerShape = @import("telar-core").PointerShape;
const CellType = @import("telar-core").Cell;
const markRows_module = @import("telar-client").markRows;
const pointer = @import("pointer.zig");
const StyleType = @import("telar-core").Style;
const screen_support = @import("screen_support.zig");
/// Two buffers and the difference between them.
///
/// `back` is what was just drawn; `front` is what the terminal is currently
/// showing. Only the cells that differ are sent. This is the whole reason a
/// terminal UI can feel immediate: a blinking cursor costs one cell, not a
/// screen, and an agent printing a megabyte still costs only the cells that
/// ended up visible.
const Screen = @This();

front: BufferType,
back: BufferType,
damage_rows: []DamageRowType,
full_damage: bool = true,
gpa: std.mem.Allocator,

/// Where to leave the terminal's own cursor, and whether to show it.
///
/// A full screen UI normally hides it and draws its own, because a hardware
/// cursor parked wherever the last write landed is a distraction. A text
/// field is the exception: the real cursor is what screen readers follow
/// and what a terminal's own input method composes against, so a field that
/// paints a block instead is invisible to both. It also blinks for free.
cursor: ?PositionType = null,
/// Desired host mouse pointer and the last shape confirmed by a successful
/// flush. `null` forces recovery to re-emit the desired shape.
mouse_pointer: PointerShape = .default,
presented_mouse_pointer: ?PointerShape = null,
graphics: ?GraphicsEffectType = null,

pub const GraphicsEffect = @import("GraphicsEffect.zig");

pub const Position = @import("Position.zig");

pub const Stats = @import("ScreenStats.zig");

pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !Screen {
    var front = try BufferType.init(gpa, w, h);
    errdefer front.deinit();
    var back = try BufferType.init(gpa, w, h);
    errdefer back.deinit();
    const damage_rows = try gpa.alloc(DamageRowType, h);
    @memset(damage_rows, .{});

    var s: Screen = .{
        .front = front,
        .back = back,
        .damage_rows = damage_rows,
        .gpa = gpa,
    };
    s.invalidate();
    return s;
}

/// Forgets what the terminal is showing, so the next frame paints all of
/// it.
///
/// Both buffers start identical, so without this the first frame would send
/// only the cells that differ from a blank screen - correct only as long as
/// the terminal really is blank. That happens to be true after the clear in
/// `Host.enter_sequence`, and depending on it is how a UI ends up drawing
/// on top of whatever the shell left behind.
pub fn invalidate(s: *Screen) void {
    // No drawn cell is ever zero width and zero length, so nothing can
    // compare equal to this.
    @memset(s.front.cells, .{ .len = 0, .width = 0 });
    s.full_damage = true;
    s.presented_mouse_pointer = null;
    @memset(s.damage_rows, .{});
}

pub fn deinit(s: *Screen) void {
    s.gpa.free(s.damage_rows);
    s.front.deinit();
    s.back.deinit();
}

/// The buffer to draw this frame into.
///
/// Arbitrary drawing cannot prove which cells it will touch, so borrowing
/// the buffer marks the whole screen. Protocol patches use `patchCells`
/// instead and retain exact damage.
pub fn buffer(s: *Screen) *BufferType {
    s.full_damage = true;
    return &s.back;
}

pub fn sizeMatches(s: *const Screen, w: u16, h: u16) bool {
    return s.back.w == w and s.back.h == h;
}

/// Returns a writable linear patch and records the rows it intersects.
/// The returned slice is valid until resize, like the backing buffer.
pub fn patchCells(s: *Screen, start: u32, count: u32) ![]CellType {
    const first: usize = start;
    const len: usize = count;
    const end = std.math.add(usize, first, len) catch return error.PatchOutOfBounds;
    if (len == 0 or end > s.back.cells.len) {
        return error.PatchOutOfBounds;
    }

    markRows_module(s.damage_rows, s.back.w, .{ .start = first, .count = len });
    return s.back.cells[first..end];
}

pub fn resize(s: *Screen, w: u16, h: u16) !void {
    const damage_rows = try s.gpa.alloc(DamageRowType, h);
    errdefer s.gpa.free(damage_rows);
    @memset(damage_rows, .{});
    try s.back.resize(w, h);
    try s.front.resize(w, h);
    s.gpa.free(s.damage_rows);
    s.damage_rows = damage_rows;
    // A resized terminal kept none of what was there.
    s.invalidate();
}

/// Sends the difference to `w`.
pub fn flush(s: *Screen, w: *std.Io.Writer) !ScreenStats {
    // The diff commits cells into `front` as it emits them. If the writer
    // fails partway, `front` claims cells the terminal never received, so
    // the only honest recovery is to forget the terminal's contents and
    // repaint everything on the next flush.
    errdefer s.invalidate();
    var stats: ScreenStats = .{};
    const before = w.end;

    // Synchronised output: the terminal is told to hold the frame until it
    // is complete. Without it a large repaint tears, because the emulator
    // draws whatever has arrived so far. herdr wraps its own draw in this.
    try w.writeAll("\x1b[?2026h");

    if (s.presented_mouse_pointer == null or
        s.presented_mouse_pointer.? != s.mouse_pointer)
    {
        try w.writeAll(pointer.sequence(s.mouse_pointer));
    }

    var last_style: ?StyleType = null;
    var cursor: ?struct { x: u16, y: u16 } = null;

    var y: u16 = 0;
    while (y < s.back.h) : (y += 1) {
        const damage = s.damage_rows[y];
        var x: u16 = if (s.full_damage) 0 else damage.start;
        const end: u16 = if (s.full_damage) s.back.w else damage.end;
        while (x < end) : (x += 1) {
            stats.scanned += 1;
            const index = @as(usize, y) * @as(usize, s.back.w) + @as(usize, x);
            const next = &s.back.cells[index];
            const current = &s.front.cells[index];

            // The trailing half of a wide glyph is not addressable: the
            // terminal advanced its own cursor over it when the first half
            // was drawn.
            if (next.width == 0) {
                current.* = next.*;
                continue;
            }
            if (next.eqlPublic(current)) {
                continue;
            }

            // One cursor move per run of changes, not per cell. On a mostly
            // unchanged screen this is where the bytes are saved.
            const contiguous = cursor != null and cursor.?.y == y and cursor.?.x == x;
            if (!contiguous) {
                try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
            }

            if (last_style == null or !last_style.?.eql(next.style)) {
                try screen_support.writeStyle(w, next.style);
                last_style = next.style;
            }

            try w.writeAll(next.text());
            stats.cells += 1;
            cursor = .{ .x = x + next.width, .y = y };
            current.* = next.*;
        }
    }

    if (s.graphics) |effect| {
        stats.graphics_bytes = try effect.write(effect.context, w);
    }
    s.graphics = null;

    // The cursor is placed after the diff, so it ends up where the caller
    // asked rather than wherever the last cell happened to be.
    if (s.cursor) |at| {
        try w.print("\x1b[{d};{d}H", .{ at.y + 1, at.x + 1 });
        try w.writeAll("\x1b[?25h");
    } else {
        try w.writeAll("\x1b[?25l");
    }

    try w.writeAll("\x1b[0m\x1b[?2026l");
    // Measured before the flush, which resets the writer's position.
    stats.bytes = w.end -| before;
    try w.flush();
    s.presented_mouse_pointer = s.mouse_pointer;
    s.full_damage = false;
    @memset(s.damage_rows, .{});
    return stats;
}
