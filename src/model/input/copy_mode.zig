//! Client-owned copy mode: cursor, selection, vim motions and frame
//! reconciliation. Everything here is pure over a cell buffer and a scroll
//! position; the client applies the returned effects.
const CopyModeFrame = @import("../state/CopyModeFrame.zig");
const CopyModeCommit = @import("../state/CopyModeCommit.zig");
const cells_module = @import("../links/cells.zig");
const CopyModePlan = @import("../state/CopyModePlan.zig");
const CopyModeProjection = @import("../state/CopyModeProjection.zig");
const PointerPress = @import("PointerPress.zig");
const tab_layout = @import("../workspace/tab_layout.zig");
const model_namespace = @import("../state/model_namespace.zig");
const model_data = @import("../model.zig");
const ClientModel = @import("../state/ClientModel.zig");
const keyinput = @import("keyinput");

const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Point = @import("Point.zig");
const Screen = @import("Screen.zig");
const State = @import("State.zig");
const Key = keyinput.Key;
const Effect = @import("Effect.zig");
const Viewport = @import("Viewport.zig");
const std = @import("std");
const View = @import("CopyModeView.zig");
const chord = keyinput.chord;

pub const Direction = @import("CopyModeDirection.zig").CopyModeDirection;

pub fn pointerSpan(point: Point, granularity: cellgrid.selection.Granularity, screen: Screen) [2]Point {
    const local: cellgrid.Point = .{
        .x = point.x,
        .y = @intCast(point.y - screen.scroll.offset),
    };
    var range = (cellgrid.SelectionRange{
        .anchor = local,
        .head = local,
        .granularity = granularity,
    }).expanded(screen.buffer);
    const row = screen.buffer.cells[@as(usize, local.y) * screen.buffer.w ..][0..screen.buffer.w];
    if (row[range.anchor.x].width == 0 and range.anchor.x > 0) {
        range.anchor.x -= 1;
    }

    if (row[range.head.x].width == 2 and range.head.x + 1 < screen.buffer.w) {
        range.head.x += 1;
    }

    return .{
        .{
            .x = range.anchor.x,
            .y = screen.scroll.offset + range.anchor.y,
        },
        .{
            .x = range.head.x,
            .y = screen.scroll.offset + range.head.y,
        },
    };
}

pub fn less(a: Point, b: Point) bool {
    return a.y < b.y or (a.y == b.y and a.x < b.x);
}

/// Interprets one key over the pane's visible cells. Pure: the only mutation
/// is the copy-mode state itself.
pub fn applyKey(state: *State, pressed: Key, screen: Screen) Effect {
    const buffer = screen.buffer;
    const scroll = screen.scroll;
    const page: i32 = @intCast(@max(@as(u16, 1), buffer.h -| 1));
    const viewport: Viewport = .{
        .scroll = scroll,
        .rows = buffer.h,
    };

    switch (pressed.code) {
        .escape => if (!state.clearSelection()) return .{
            .exit = true,
        },
        .enter => return .{
            .exit = true,
            .copy = true,
        },
        .left => state.horizontal(-1, buffer.w),
        .right => state.horizontal(1, buffer.w),
        .up => state.vertical(-1, viewport),
        .down => state.vertical(1, viewport),
        .home => state.lineStart(),
        .end => lastNonBlank(
            state,
            buffer,
            scroll,
        ),
        .page_up => state.vertical(-page, viewport),
        .page_down => state.vertical(page, viewport),
        .char => |char| if (pressed.mods.ctrl) {
            if (char.eql("b")) {
                state.vertical(-page, viewport);
            } else if (char.eql("f")) {
                state.vertical(page, viewport);
            } else if (char.eql("u")) {
                state.vertical(-@divTrunc(page, 2), viewport);
            } else if (char.eql("d")) {
                state.vertical(@divTrunc(page, 2), viewport);
            } else {
                return .{
                    .handled = false,
                };
            }
        } else if (char.eql("h")) {
            state.horizontal(-1, buffer.w);
        } else if (char.eql("j")) {
            state.vertical(1, viewport);
        } else if (char.eql("k")) {
            state.vertical(-1, viewport);
        } else if (char.eql("l")) {
            state.horizontal(1, buffer.w);
        } else if (char.eql("0")) {
            state.lineStart();
        } else if (char.eql("^")) {
            firstNonBlank(
                state,
                buffer,
                scroll,
            );
        } else if (char.eql("$")) {
            lastNonBlank(
                state,
                buffer,
                scroll,
            );
        } else if (char.eql("w")) {
            wordForward(
                state,
                screen,
                false,
            );
        } else if (char.eql("e")) {
            wordForward(
                state,
                screen,
                true,
            );
        } else if (char.eql("b")) {
            wordBackward(
                state,
                buffer,
                scroll,
            );
        } else if (char.eql("{")) {
            paragraph(
                state,
                screen,
                -1,
            );
        } else if (char.eql("}")) {
            paragraph(
                state,
                screen,
                1,
            );
        } else if (char.eql("g")) {
            state.top();
        } else if (char.eql("G")) {
            state.bottom(scroll, buffer.h);
        } else if (char.eql("/")) {
            state.search_direction = .forward;
            return .{
                .search = .forward,
            };
        } else if (char.eql("?")) {
            state.search_direction = .backward;
            return .{
                .search = .backward,
            };
        } else if (char.eql("n")) {
            state.cycleMatch(if (state.search_direction == .forward) 1 else -1, viewport);
        } else if (char.eql("N")) {
            state.cycleMatch(if (state.search_direction == .forward) -1 else 1, viewport);
        } else if (char.eql("o")) {
            return .{
                .open_link = true,
            };
        } else if (char.eql("v") or char.eql(" ")) {
            state.toggleSelection(false);
        } else if (char.eql("V")) {
            state.toggleSelection(true);
        } else if (char.eql("y")) {
            return .{
                .exit = true,
                .copy = true,
            };
        } else if (char.eql("q")) {
            return .{
                .exit = true,
            };
        } else {
            return .{
                .handled = false,
            };
        },
        else => return .{
            .handled = false,
        },
    }
    return .{};
}

/// Reconciles the copy cursor with a runtime frame. Pruned scrollback pulls
/// the cursor and anchor up with it while the viewport sat at the pruned
/// edge; both are then clamped to the new history length.
pub fn onFrame(state: *State, previous_offset: u32, scroll: core.Scroll) void {
    if (scroll.offset < previous_offset and state.viewport_offset == previous_offset) {
        const pruned = previous_offset - scroll.offset;
        state.cursor.y -|= pruned;
        if (state.pointer) |*pointer| {
            pointer.start.y -|= pruned;
            pointer.end.y -|= pruned;
        }

        if (state.anchor) |*anchor| {
            anchor.y -|= pruned;
        }
    }
    state.cursor.y = @min(state.cursor.y, scroll.total_rows -| 1);
    if (state.pointer) |*pointer| {
        pointer.start.y = @min(pointer.start.y, scroll.total_rows -| 1);
        pointer.end.y = @min(pointer.end.y, scroll.total_rows -| 1);
    }

    if (state.anchor) |*anchor| {
        anchor.y = @min(anchor.y, scroll.total_rows -| 1);
    }
    state.viewport_offset = scroll.offset;
}

const WordClass = enum { space, word, punctuation };

fn rowIndex(buffer: *const cellgrid.Buffer, scroll: core.Scroll, absolute_y: u32) ?u16 {
    if (absolute_y < scroll.offset or absolute_y >= scroll.offset + buffer.h) {
        return null;
    }
    return @intCast(absolute_y - scroll.offset);
}

fn firstNonBlank(state: *State, buffer: *const cellgrid.Buffer, scroll: core.Scroll) void {
    const row = rowIndex(
        buffer,
        scroll,
        state.cursor.y,
    ) orelse return state.lineStart();
    var x: u16 = 0;
    while (x < buffer.w) : (x += 1) {
        const text = buffer.cells[@as(usize, row) * buffer.w + x].text();
        if (text.len != 0 and !std.ascii.isWhitespace(text[0])) {
            break;
        }
    }
    state.cursor.x = @min(x, buffer.w -| 1);
}

fn lastNonBlank(state: *State, buffer: *const cellgrid.Buffer, scroll: core.Scroll) void {
    const row = rowIndex(
        buffer,
        scroll,
        state.cursor.y,
    ) orelse return state.lineEnd(buffer.w);
    var x = buffer.w;
    while (x != 0) {
        x -= 1;
        const text = buffer.cells[@as(usize, row) * buffer.w + x].text();
        if (text.len != 0 and !std.ascii.isWhitespace(text[0])) {
            break;
        }
    }
    state.cursor.x = x;
}

fn paragraph(state: *State, screen: Screen, direction: i32) void {
    const buffer = screen.buffer;
    const scroll = screen.scroll;
    var y = state.cursor.y;
    while (true) {
        const next = if (direction < 0) y -| 1 else @min(y +| 1, scroll.total_rows -| 1);
        if (next == y) {
            break;
        }
        y = next;
        const row = rowIndex(
            buffer,
            scroll,
            y,
        ) orelse break;
        var blank = true;
        for (buffer.cells[@as(usize, row) * buffer.w ..][0..buffer.w]) |cell| {
            const text = cell.text();
            if (text.len != 0 and !std.ascii.isWhitespace(text[0])) {
                blank = false;
                break;
            }
        }
        if (blank) {
            break;
        }
    }
    state.cursor.y = y;
    state.cursor.x = 0;
    state.vertical(
        0,
        .{
            .scroll = scroll,
            .rows = buffer.h,
        },
    );
}

fn wordClass(buffer: *const cellgrid.Buffer, scroll: core.Scroll, point: Point) ?WordClass {
    const row = rowIndex(
        buffer,
        scroll,
        point.y,
    ) orelse return null;
    const cell = buffer.cells[@as(usize, row) * buffer.w + point.x];
    const text = cell.text();
    if (text.len == 0 or std.ascii.isWhitespace(text[0])) {
        return .space;
    }
    return if (std.ascii.isAlphanumeric(text[0]) or text[0] == '_')
        .word
    else
        .punctuation;
}

fn nextPoint(point: Point, cols: u16, total_rows: u32) Point {
    if (point.x + 1 < cols) {
        return .{
            .x = point.x + 1,
            .y = point.y,
        };
    }
    if (point.y + 1 < total_rows) {
        return .{
            .x = 0,
            .y = point.y + 1,
        };
    }
    return point;
}

fn previousPoint(point: Point, cols: u16) Point {
    if (point.x != 0) {
        return .{
            .x = point.x - 1,
            .y = point.y,
        };
    }
    if (point.y != 0) {
        return .{
            .x = cols - 1,
            .y = point.y - 1,
        };
    }
    return point;
}

fn wordForward(state: *State, screen: Screen, end: bool) void {
    const buffer = screen.buffer;
    const scroll = screen.scroll;
    const initial = wordClass(
        buffer,
        scroll,
        state.cursor,
    ) orelse {
        state.vertical(
            1,
            .{
                .scroll = scroll,
                .rows = buffer.h,
            },
        );
        state.lineStart();
        return;
    };
    var point = state.cursor;
    if (end and initial != .space) {
        while (true) {
            const next = nextPoint(
                point,
                buffer.w,
                scroll.total_rows,
            );
            if (std.meta.eql(next, point) or wordClass(
                buffer,
                scroll,
                next,
            ) != initial) {
                break;
            }
            point = next;
        }
    } else {
        while (wordClass(
            buffer,
            scroll,
            point,
        )) |class| {
            if (class != initial) {
                break;
            }
            const next = nextPoint(
                point,
                buffer.w,
                scroll.total_rows,
            );
            if (std.meta.eql(next, point)) {
                break;
            }
            point = next;
        }
        while (wordClass(
            buffer,
            scroll,
            point,
        ) == .space) {
            const next = nextPoint(
                point,
                buffer.w,
                scroll.total_rows,
            );
            if (std.meta.eql(next, point)) {
                break;
            }
            point = next;
        }
        if (end) {
            const class = wordClass(
                buffer,
                scroll,
                point,
            ) orelse .space;
            while (true) {
                const next = nextPoint(
                    point,
                    buffer.w,
                    scroll.total_rows,
                );
                if (std.meta.eql(next, point) or wordClass(
                    buffer,
                    scroll,
                    next,
                ) != class) {
                    break;
                }
                point = next;
            }
        }
    }
    state.cursor = point;
    state.vertical(
        0,
        .{
            .scroll = scroll,
            .rows = buffer.h,
        },
    );
}

fn wordBackward(state: *State, buffer: *const cellgrid.Buffer, scroll: core.Scroll) void {
    var point = previousPoint(state.cursor, buffer.w);
    while (wordClass(
        buffer,
        scroll,
        point,
    ) == .space) {
        const previous = previousPoint(point, buffer.w);
        if (std.meta.eql(previous, point)) {
            break;
        }
        point = previous;
    }
    const class = wordClass(
        buffer,
        scroll,
        point,
    ) orelse {
        state.vertical(
            -1,
            .{
                .scroll = scroll,
                .rows = buffer.h,
            },
        );
        state.lineStart();
        return;
    };
    while (true) {
        const previous = previousPoint(point, buffer.w);
        if (std.meta.eql(previous, point) or wordClass(
            buffer,
            scroll,
            previous,
        ) != class) {
            break;
        }
        point = previous;
    }
    state.cursor = point;
    state.vertical(
        0,
        .{
            .scroll = scroll,
            .rows = buffer.h,
        },
    );
}

test "vertical movement scrolls the viewport only at its edges" {
    const scroll: core.Scroll = .{
        .total_rows = 100,
        .offset = 90,
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 2,
            .y = 99,
        },
        90,
    );
    state.vertical(
        -1,
        .{
            .scroll = scroll,
            .rows = 10,
        },
    );
    try std.testing.expectEqual(@as(u32, 90), state.viewport_offset);
    state.vertical(
        -20,
        .{
            .scroll = scroll,
            .rows = 10,
        },
    );
    try std.testing.expectEqual(@as(u32, 78), state.cursor.y);
    try std.testing.expectEqual(@as(u32, 78), state.viewport_offset);
}

test "pointer selection includes both cells of wide glyphs without copying a bare click" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        10,
        2,
    );
    defer buffer.deinit();
    buffer.fill(
        buffer.area(),
        .{
            .glyph = " ",
            .style = .{},
        },
    );
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = "a界b",
            .style = .{},
        },
    );
    const screen: Screen = .{
        .buffer = &buffer,
        .scroll = .{
            .offset = 0,
            .total_rows = 2,
        },
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 2,
            .y = 0,
        },
        0,
    );
    state.beginPointer(.character, screen);
    state.movePointer(
        .{
            .position = .{
                .x = 2,
                .y = 0,
            },
            .release = true,
        },
        screen,
    );
    try std.testing.expect(state.anchor == null);

    state.movePointer(
        .{
            .position = .{
                .x = 3,
                .y = 0,
            },
        },
        screen,
    );
    try std.testing.expectEqual(@as(u16, 1), state.anchor.?.x);
    try std.testing.expectEqual(@as(u16, 3), state.cursor.x);
    try std.testing.expect(state.view().selected(2, 0));
}

test "pointer word drags retain the original word when reversing direction" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        13,
        2,
    );
    defer buffer.deinit();
    buffer.fill(
        buffer.area(),
        .{
            .glyph = " ",
            .style = .{},
        },
    );
    _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = 0,
            },
            .text = "one two three",
            .style = .{},
        },
    );
    const screen: Screen = .{
        .buffer = &buffer,
        .scroll = .{
            .offset = 100,
            .total_rows = 102,
        },
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 5,
            .y = 100,
        },
        100,
    );
    state.beginPointer(.word, screen);
    state.movePointer(
        .{
            .position = .{
                .x = 10,
                .y = 0,
            },
        },
        screen,
    );
    try std.testing.expectEqualDeep(
        Point{
            .x = 4,
            .y = 100,
        },
        state.anchor.?,
    );
    try std.testing.expectEqualDeep(
        Point{
            .x = 12,
            .y = 100,
        },
        state.cursor,
    );

    state.movePointer(
        .{
            .position = .{
                .x = 1,
                .y = 0,
            },
        },
        screen,
    );
    try std.testing.expectEqualDeep(
        Point{
            .x = 6,
            .y = 100,
        },
        state.anchor.?,
    );
    try std.testing.expectEqualDeep(
        Point{
            .x = 0,
            .y = 100,
        },
        state.cursor,
    );
    state.movePointer(
        .{
            .position = .{
                .x = 65535,
                .y = 65535,
            },
        },
        screen,
    );
    try std.testing.expectEqualDeep(
        Point{
            .x = 12,
            .y = 101,
        },
        state.cursor,
    );
}

test "pruned history moves the captured pointer origin with its highlight" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        10,
        2,
    );
    defer buffer.deinit();
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 2,
            .y = 100,
        },
        100,
    );
    state.beginPointer(
        .character,
        .{
            .buffer = &buffer,
            .scroll = .{
                .offset = 100,
                .total_rows = 102,
            },
        },
    );
    const scroll: core.Scroll = .{
        .offset = 90,
        .total_rows = 92,
    };
    onFrame(
        &state,
        100,
        scroll,
    );
    state.movePointer(
        .{
            .position = .{
                .x = 4,
                .y = 0,
            },
        },
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );

    try std.testing.expectEqualDeep(
        Point{
            .x = 2,
            .y = 90,
        },
        state.anchor.?,
    );
    try std.testing.expectEqualDeep(
        Point{
            .x = 4,
            .y = 90,
        },
        state.cursor,
    );
}

test "linear and linewise selections are inclusive" {
    const linear: View = .{
        .anchor = .{
            .x = 3,
            .y = 4,
        },
        .cursor = .{
            .x = 1,
            .y = 5,
        },
        .linewise = false,
    };
    try std.testing.expect(linear.selected(3, 4));
    try std.testing.expect(linear.selected(0, 5));
    try std.testing.expect(!linear.selected(2, 5));

    const linewise: View = .{
        .anchor = .{
            .x = 3,
            .y = 4,
        },
        .cursor = .{
            .x = 1,
            .y = 5,
        },
        .linewise = true,
    };
    try std.testing.expect(linewise.selected(99, 4));
    try std.testing.expect(linewise.selected(99, 5));
}

fn testScreen(gpa: std.mem.Allocator, rows: []const []const u8) !cellgrid.Buffer {
    var width: u16 = 0;
    for (rows) |row| width = @max(width, @as(u16, @intCast(row.len)));
    var buffer = try cellgrid.Buffer.init(
        gpa,
        width,
        @intCast(rows.len),
    );
    buffer.fill(
        buffer.area(),
        .{
            .glyph = " ",
            .style = .{},
        },
    );
    for (rows, 0..) |row, y| _ = buffer.writeText(
        buffer.area(),
        .{
            .point = .{
                .x = 0,
                .y = @intCast(y),
            },
            .text = row,
            .style = .{},
        },
    );
    return buffer;
}

test "word motions travel by class over the visible cells" {
    const gpa = std.testing.allocator;
    var buffer = try testScreen(gpa, &.{
        "foo bar,baz",
        "        end",
    });
    defer buffer.deinit();
    const scroll: core.Scroll = .{
        .total_rows = 2,
        .offset = 0,
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 0,
            .y = 0,
        },
        0,
    );

    _ = applyKey(
        &state,
        try chord.parseKey("w"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expectEqual(@as(u16, 4), state.cursor.x);
    _ = applyKey(
        &state,
        try chord.parseKey("w"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expectEqual(@as(u16, 7), state.cursor.x);
    _ = applyKey(
        &state,
        try chord.parseKey("b"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expectEqual(@as(u16, 4), state.cursor.x);
    _ = applyKey(
        &state,
        try chord.parseKey("$"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expectEqual(@as(u16, 10), state.cursor.x);
    _ = applyKey(
        &state,
        try chord.parseKey("0"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expectEqual(@as(u16, 0), state.cursor.x);
}

test "escape clears the selection before it exits" {
    const gpa = std.testing.allocator;
    var buffer = try testScreen(gpa, &.{
        "abc",
    });
    defer buffer.deinit();
    const scroll: core.Scroll = .{
        .total_rows = 1,
        .offset = 0,
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 0,
            .y = 0,
        },
        0,
    );

    _ = applyKey(
        &state,
        try chord.parseKey("v"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expect(state.anchor != null);
    const cleared = applyKey(
        &state,
        try chord.parseKey("escape"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expect(!cleared.exit);
    try std.testing.expect(state.anchor == null);
    const exited = applyKey(
        &state,
        try chord.parseKey("escape"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expect(exited.exit and !exited.copy);
    const copied = applyKey(
        &state,
        try chord.parseKey("y"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expect(copied.exit and copied.copy);
    const ignored = applyKey(
        &state,
        try chord.parseKey("z"),
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expect(!ignored.handled);
}

test "a pruning frame pulls cursor and anchor up before clamping" {
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 0,
            .y = 50,
        },
        40,
    );
    state.anchor = .{
        .x = 0,
        .y = 45,
    };

    // Ten rows pruned while the viewport sat at the pruned edge.
    onFrame(
        &state,
        40,
        .{
            .total_rows = 55,
            .offset = 30,
        },
    );
    try std.testing.expectEqual(@as(u32, 40), state.cursor.y);
    try std.testing.expectEqual(@as(u32, 35), state.anchor.?.y);
    try std.testing.expectEqual(@as(u32, 30), state.viewport_offset);

    // A shrunken history clamps both; the viewport did not sit at the
    // pruned edge this time, so nothing is pulled up first.
    onFrame(
        &state,
        99,
        .{
            .total_rows = 20,
            .offset = 0,
        },
    );
    try std.testing.expectEqual(@as(u32, 19), state.cursor.y);
    try std.testing.expectEqual(@as(u32, 19), state.anchor.?.y);
}

test "matches select relative to the cursor, highlight and cycle with wrap" {
    const scroll: core.Scroll = .{
        .total_rows = 40,
        .offset = 0,
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 0,
            .y = 10,
        },
        0,
    );
    const results = [_]core.SearchMatch{
        .{
            .x = 2,
            .y = 4,
            .len = 3,
        },
        .{
            .x = 1,
            .y = 12,
            .len = 2,
        },
        .{
            .x = 5,
            .y = 30,
            .len = 4,
        },
    };

    state.applyMatches(
        &results,
        .{
            .scroll = scroll,
            .rows = 5,
        },
    );
    try std.testing.expectEqual(@as(u8, 1), state.match_index);
    try std.testing.expectEqualDeep(
        Point{
            .x = 1,
            .y = 12,
        },
        state.anchor.?,
    );
    try std.testing.expectEqualDeep(
        Point{
            .x = 2,
            .y = 12,
        },
        state.cursor,
    );

    state.cycleMatch(
        1,
        .{
            .scroll = scroll,
            .rows = 5,
        },
    );
    try std.testing.expectEqual(@as(u8, 2), state.match_index);
    state.cycleMatch(
        1,
        .{
            .scroll = scroll,
            .rows = 5,
        },
    );
    try std.testing.expectEqual(@as(u8, 0), state.match_index);
    try std.testing.expect(state.viewport_offset <= 4);

    state.search_direction = .backward;
    state.cursor = .{
        .x = 0,
        .y = 10,
    };
    state.applyMatches(
        &results,
        .{
            .scroll = scroll,
            .rows = 5,
        },
    );
    try std.testing.expectEqual(@as(u8, 0), state.match_index);

    state.applyMatches(
        &.{},
        .{
            .scroll = scroll,
            .rows = 5,
        },
    );
    try std.testing.expectEqual(@as(u8, 0), state.match_count);
}

test "slash and question mark ask for the search input" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        10,
        5,
    );
    defer buffer.deinit();
    const scroll: core.Scroll = .{
        .total_rows = 5,
        .offset = 0,
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 0,
            .y = 0,
        },
        0,
    );

    const forward = applyKey(
        &state,
        .{
            .code = .{
                .char = .init("/"),
            },
        },
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expectEqual(Direction.forward, forward.search.?);
    const backward = applyKey(
        &state,
        .{
            .code = .{
                .char = .init("?"),
            },
        },
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );
    try std.testing.expectEqual(Direction.backward, backward.search.?);
    try std.testing.expectEqual(Direction.backward, state.search_direction);
}

test "o asks the client to open the link under the cursor" {
    var buffer = try cellgrid.Buffer.init(
        std.testing.allocator,
        10,
        5,
    );
    defer buffer.deinit();
    const scroll: core.Scroll = .{
        .total_rows = 5,
        .offset = 0,
    };
    var state = State.init(
        @enumFromInt(1),
        .{
            .x = 0,
            .y = 0,
        },
        0,
    );

    const effect = applyKey(
        &state,
        .{
            .code = .{
                .char = .init("o"),
            },
        },
        .{
            .buffer = &buffer,
            .scroll = scroll,
        },
    );

    try std.testing.expect(effect.open_link);
    try std.testing.expect(!effect.exit);
}

/// Reports whether copy mode currently owns pane input.
///
/// ```zig
/// if (copy_mode.isActive(model)) return;
/// ```
pub fn isActive(model: *const ClientModel) bool {
    const state = model.copy_state orelse return false;

    return state.pointer == null;
}

/// Returns the pointer gesture's stable owner without lending its state.
/// Example: `const target = copy_mode.pointerSelection(model) orelse return;`.
pub fn pointerSelection(model: *const ClientModel) ?struct { pane_id: core.PaneId, dragging: bool } {
    if (model.selection_gesture) |pane_id| {
        return .{ .pane_id = pane_id, .dragging = true };
    }

    const state = model.copy_state orelse return null;
    if (state.pointer == null) {
        return null;
    }

    return .{ .pane_id = state.pane_id, .dragging = false };
}

/// Releases physical capture even when copying fails or the pane retired.
/// Example: `copy_mode.finishPointerGesture(model);`.
pub fn finishPointerGesture(model: *ClientModel) void {
    model.selection_gesture = null;
}

/// Clears disposable mouse highlighting before typing or pasting.
/// Example: `_ = copy_mode.clearPointerSelection(model);`.
pub fn clearPointerSelection(model: *ClientModel) bool {
    const state = model.copy_state orelse return false;
    if (state.pointer == null) {
        return false;
    }

    return release(model, state.pane_id);
}

/// Starts selection only after routing has focused an attached pane.
/// Example: `_ = copy_mode.beginPointerSelection(model, press);`.
pub fn beginPointerSelection(model: *ClientModel, press: PointerPress) bool {
    if (isActive(model) or model.name_prompt.active() or model.pane_paste != null) {
        return false;
    }

    const slot = model.tabs.activeSlot() orelse return false;
    const pane = tab_layout.focusedPane(model, slot) orelse return false;
    if (pane.id != press.pane_id or !pane.attached or pane.kind != .terminal or
        press.position.x >= pane.buffer.w or press.position.y >= pane.buffer.h)
    {
        return false;
    }

    if (model.selection_click_pane != pane.id) {
        model.selection_clicks = .{};
    }

    model.selection_click_pane = pane.id;
    const granularity = model.selection_clicks.press(press.position, press.now_ns);
    var state = model_data.State.init(pane.id, .{
        .x = press.position.x,
        .y = pane.scroll.offset + press.position.y,
    }, pane.scroll.offset);
    state.beginPointer(granularity, .{ .buffer = &pane.buffer, .scroll = pane.scroll });
    model.selection_gesture = pane.id;
    model.copy_state = state;
    model.copy_revision +%= 1;
    return true;
}

/// Returns the pane captured by active copy mode.
///
/// ```zig
/// const pane_id = copy_mode.targetPane(model) orelse return;
/// ```
pub fn targetPane(model: *const ClientModel) ?core.PaneId {
    const state = model.copy_state orelse return null;

    return state.pane_id;
}

/// Returns the immutable copy-mode projection consumed by presenters.
///
/// ```zig
/// const projection = copy_mode.currentProjection(model) orelse return;
/// ```
pub fn currentProjection(model: *const ClientModel) ?CopyModeProjection {
    const state = model.copy_state orelse return null;

    return .{ .pane_id = state.pane_id, .view = state.view() };
}

/// Enters copy mode on the attached focused pane. An active prompt or
/// paste, missing pane or repeated request leaves the copy revision intact.
///
/// ```zig
/// if (copy_mode.enter(model)) observe(model.version());
/// ```
pub fn enter(model: *ClientModel) bool {
    if (isActive(model) or model.name_prompt.active() or model.pane_paste != null) {
        return false;
    }

    const slot = model.tabs.activeSlot() orelse return false;
    const pane = tab_layout.focusedPane(model, slot) orelse return false;
    if (!pane.attached or pane.kind != .terminal) {
        return false;
    }

    const cursor: model_data.Point = if (pane.cursor.visible)
        .{ .x = pane.cursor.x, .y = pane.scroll.offset + pane.cursor.y }
    else
        .{ .x = 0, .y = pane.scroll.offset + pane.buffer.h -| 1 };
    model.copy_state = model_data.State.init(pane.id, cursor, pane.scroll.offset);
    model.copy_revision +%= 1;
    return true;
}

/// Plans one copy-mode command without mutating state or performing
/// runtime effects. Missing targets plan a local exit.
///
/// ```zig
/// const plan = copy_mode.planCommand(model, .{ .key = key }) orelse return;
/// ```
pub fn planCommand(model: *const ClientModel, command: model_data.CopyModeCommand) ?CopyModePlan {
    const previous = model.copy_state orelse return null;
    const pane = model.activePaneConst(previous.pane_id) orelse
        return planExit(model, previous, null);
    var next = previous;

    switch (command) {
        .key => |pressed| {
            const effect = model_data.copy_mode.applyKey(&next, pressed, .{ .buffer = &pane.buffer, .scroll = pane.scroll });
            if (!effect.handled) {
                return null;
            }
            if (effect.search) |direction| {
                return .{
                    .expected_revision = model.copy_revision,
                    .previous = previous,
                    .next = next,
                    .viewport = model_namespace.copyModeViewport(pane, next.viewport_offset),
                    .search = direction,
                };
            }
            if (effect.open_link) {
                const target = cells_module.extract(&pane.buffer, pane.scroll, .{
                    .x = next.cursor.x,
                    .y = next.cursor.y,
                }) orelse return null;

                return .{
                    .expected_revision = model.copy_revision,
                    .previous = previous,
                    .next = next,
                    .open_link = target,
                };
            }
            if (effect.exit) {
                const selection: ?core.CopySelection = if (effect.copy and next.anchor != null) .{
                    .pane_id = next.pane_id,
                    .start_x = next.anchor.?.x,
                    .start_y = next.anchor.?.y,
                    .end_x = next.cursor.x,
                    .end_y = next.cursor.y,
                    .linewise = next.linewise,
                } else null;

                return planExit(model, previous, selection);
            }
        },
        .pointer => |motion| {
            if (previous.pointer == null or model.selection_gesture != previous.pane_id) {
                return null;
            }

            next.movePointer(motion, .{ .buffer = &pane.buffer, .scroll = pane.scroll });
            if (motion.release) {
                const anchor = next.anchor orelse return planExit(model, previous, null);

                return .{
                    .expected_revision = model.copy_revision,
                    .previous = previous,
                    .next = next,
                    .selection = .{
                        .pane_id = next.pane_id,
                        .start_x = anchor.x,
                        .start_y = anchor.y,
                        .end_x = next.cursor.x,
                        .end_y = next.cursor.y,
                        .linewise = next.linewise,
                    },
                };
            }
        },
        .cancel_pointer => {
            if (previous.pointer == null) {
                return null;
            }

            return planExit(model, previous, null);
        },
        .vertical => |delta| next.vertical(delta, .{ .scroll = pane.scroll, .rows = pane.buffer.h }),
        .matches => |found| {
            if (found.pane_id != previous.pane_id or previous.pointer != null) {
                return null;
            }

            next.applyMatches(found.matches, .{ .scroll = pane.scroll, .rows = pane.buffer.h });
        },
        .leave => return planExit(model, previous, null),
    }

    if (std.meta.eql(previous, next)) {
        return null;
    }

    return .{
        .expected_revision = model.copy_revision,
        .previous = previous,
        .next = next,
        .viewport = model_namespace.copyModeViewport(pane, next.viewport_offset),
    };
}

/// Commits a current copy-mode plan and returns the post-commit runtime
/// synchronization. Stale plans leave state untouched.
///
/// ```zig
/// const commit = copy_mode.commitPlan(model, plan) orelse return;
/// ```
pub fn commitPlan(model: *ClientModel, plan: CopyModePlan) ?CopyModeCommit {
    if (model.copy_revision != plan.expected_revision) {
        return null;
    }

    const current = model.copy_state orelse return null;
    if (!std.meta.eql(current, plan.previous)) {
        return null;
    }

    if (plan.next) |next| {
        if (model.activePaneConst(next.pane_id) == null) {
            return null;
        }
    }

    var viewport_change: ?model_data.PaneViewportChange = null;
    if (plan.viewport) |viewport| {
        const slot = model.tabs.activeSlot() orelse return null;
        const pane = model.panes.findIn(model.tabs.location[slot].tab_id, viewport.pane_id) orelse return null;
        if (viewport.offset > pane.scroll.maxOffset(pane.buffer.h)) {
            return null;
        }

        viewport_change = model_namespace.commitPaneViewport(model, pane, viewport.offset);
    }

    model.copy_state = plan.next;
    model.copy_revision +%= 1;

    return .{
        .active = plan.next != null,
        .viewport = viewport_change,
        .copy_revision = model.copy_revision,
    };
}

/// Releases copy mode only when it targets the retired pane.
///
/// ```zig
/// _ = copy_mode.release(model, pane_id);
/// ```
pub fn release(model: *ClientModel, pane_id: core.PaneId) bool {
    const state = model.copy_state orelse return false;
    if (state.pane_id != pane_id) {
        return false;
    }

    model.copy_state = null;
    model.copy_revision +%= 1;
    return true;
}

pub fn reconcileFrame(model: *ClientModel, command: CopyModeFrame) bool {
    const state = model.copy_state orelse return false;
    if (state.pane_id != command.pane_id) {
        return false;
    }

    if (state.pointer) |pointer| {
        const pane = model.activePaneConst(state.pane_id) orelse return release(model, state.pane_id);
        if (pointer.cols != pane.buffer.w or pointer.rows != pane.buffer.h) {
            return release(model, state.pane_id);
        }
    }

    var next = state;
    model_data.copy_mode.onFrame(&next, command.previous_offset, command.scroll);
    if (std.meta.eql(state, next)) {
        return false;
    }

    model.copy_state = next;
    model.copy_revision +%= 1;
    return true;
}

fn planExit(model: *const ClientModel, previous: model_data.State, selection: ?core.CopySelection) CopyModePlan {
    const pane = model.activePaneConst(previous.pane_id);
    const viewport = if (pane != null and previous.pointer == null)
        model_namespace.copyModeViewport(pane.?, previous.entry_offset)
    else
        null;

    return .{
        .expected_revision = model.copy_revision,
        .previous = previous,
        .next = null,
        .selection = selection,
        .viewport = viewport,
    };
}
