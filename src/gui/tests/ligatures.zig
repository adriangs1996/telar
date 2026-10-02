const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const CellMesh = @import("../render/CellMesh.zig");
const gfx = @import("gfx");
const QuadList = gfx.QuadList;
const Quad = gfx.Quad.Quad;

/// Sequences the embedded JetBrains Mono substitutes through `calt`; each
/// was checked with `hb-shape` against `src/assets/JetBrainsMono-Regular.ttf`.
const sequences = [_][]const u8{ "->", "!=", "=>", "==", "===", "<=", ">=", "!==", "&&", "||", "::", "/*", "<!--", "|>" };

test "operator sequences draw the embedded font's ligatures across their cells" {
    const session = try configured();
    defer session.deinit();
    for (sequences) |sequence| {
        clear(session);
        write(session, .{ 2, 1 }, sequence);
        try paint(session);
        var whole = try shapedTogether(session, .{ 2, 1 }, sequence);
        defer whole.deinit();
        var alone = try shapedAlone(session, .{ 2, 1 }, sequence);
        defer alone.deinit();
        try std.testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(whole.items()), std.mem.sliceAsBytes(alone.items())));
        var drawn = try retainedInk(session, .{ 2, 1 }, sequence.len);
        defer drawn.deinit();
        try expectSameGlyphs(whole.items(), drawn.items());
    }
}

// Each cell anchors its glyphs at its own grid column, as Ghostty does, so
// a glyph lands within a pixel of where one continuous pen puts it; the
// textures, sizes, baselines and colors are exactly the line's.
fn expectSameGlyphs(expected: []const Quad, actual: []const Quad) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |line, cell| {
        var anchored = cell;
        anchored.x = line.x;
        try std.testing.expectEqualDeep(line, anchored);
        try std.testing.expectApproxEqAbs(line.x, cell.x, 1);
    }
}

test "typing forms and breaking a ligature repaints every cell it covers and nothing else" {
    const session = try configured();
    defer session.deinit();
    const renderer = &session.gui.renderer;
    write(session, .{ 2, 1 }, "a -");
    try paint(session);
    try expectAlone(session, .{ 2, 1 }, "a -");

    // `>` turns the `-` before it into the ligature's spacer.
    write(session, .{ 5, 1 }, ">");
    try paint(session);
    try std.testing.expectEqual(@as(usize, 2), renderer.repainted_cells);
    try expectLigature(session, .{ 4, 1 }, "->");
    try expectRedrawMatches(session);

    // Replacing `>` gives the untouched `-` its own glyph back.
    write(session, .{ 5, 1 }, "x");
    try paint(session);
    try std.testing.expectEqual(@as(usize, 2), renderer.repainted_cells);
    try expectAlone(session, .{ 2, 1 }, "a -x");
    try expectRedrawMatches(session);

    // Editing the middle of `===` repaints the cells whose glyphs change:
    // `=!=` keeps the first spacer, `= =` changes all three.
    clear(session);
    write(session, .{ 2, 1 }, "x === y");
    try paint(session);
    try expectLigature(session, .{ 4, 1 }, "===");
    write(session, .{ 5, 1 }, "!");
    try paint(session);
    try std.testing.expectEqual(@as(usize, 2), renderer.repainted_cells);
    try expectLigature(session, .{ 4, 1 }, "=!=");
    try expectRedrawMatches(session);
    write(session, .{ 5, 1 }, " ");
    try paint(session);
    try std.testing.expectEqual(@as(usize, 3), renderer.repainted_cells);
    try expectAlone(session, .{ 2, 1 }, "x = = y");
    try expectRedrawMatches(session);
}

test "ligatures stop at ink style, row and fallback boundaries but not at backgrounds or underlines" {
    const session = try configured();
    defer session.deinit();
    const target = pane(session);
    const w = target.buffer.w;

    // Bold or another color splits the run; a background or an underline does not.
    write(session, .{ 2, 1 }, "->");
    target.buffer.cells[w + 3].style.flags.bold = true;
    try paint(session);
    try expectAlone(session, .{ 2, 1 }, "->");
    target.buffer.cells[w + 3].style = .{ .fg = .indexed(2) };
    try paint(session);
    try expectAlone(session, .{ 2, 1 }, "->");
    target.buffer.cells[w + 3].style = .{ .bg = .indexed(1) };
    target.buffer.cells[w + 2].style = .{ .flags = .{ .underline = .single } };
    try paint(session);
    try expectLigature(session, .{ 2, 1 }, "->");
    try expectRedrawMatches(session);

    // A ligature never crosses the end of a row.
    clear(session);
    write(session, .{ w - 1, 1 }, "-");
    write(session, .{ 0, 2 }, ">");
    try paint(session);
    try expectAlone(session, .{ w - 1, 1 }, "-");
    try expectAlone(session, .{ 0, 2 }, ">");

    // A fallback icon or a procedural box splits the run around it.
    clear(session);
    const icon = "\u{f07b}";
    write(session, .{ 2, 1 }, "-");
    setText(session, .{ 3, 1 }, icon);
    write(session, .{ 4, 1 }, ">");
    setText(session, .{ 5, 1 }, "\u{2502}");
    write(session, .{ 6, 1 }, "=>");
    try paint(session);
    try expectAlone(session, .{ 2, 1 }, "-");
    try expectAlone(session, .{ 4, 1 }, ">");
    try expectLigature(session, .{ 6, 1 }, "=>");
    try expectRedrawMatches(session);
}

test "the cursor and a partial selection show the characters under them" {
    const session = try configured();
    defer session.deinit();
    const renderer = &session.gui.renderer;
    const target = pane(session);
    write(session, .{ 2, 1 }, "->");
    target.cursor = .{ .visible = true, .x = 3, .y = 1, .appearance = .{ .shape = .block } };
    renderer.theme.cursor_text_color = .{
        0,
        255,
        0,
    };
    try paint(session);
    try expectAlone(session, .{ 2, 1 }, "->");
    var alone = try shapedAlone(session, .{ 3, 1 }, ">");
    defer alone.deinit();
    var recolored = alone.items()[0];
    recolored.r = 0;
    recolored.g = 1;
    recolored.b = 0;
    var found = false;
    for (renderer.quads.items()) |quad| {
        found = found or std.meta.eql(quad, recolored);
    }
    try std.testing.expect(found);

    // A blink keeps the split; leaving the run forms the ligature again.
    renderer.cursor_on = false;
    try paint(session);
    try std.testing.expectEqual(@as(usize, 0), renderer.repainted_cells);
    renderer.cursor_on = true;
    target.cursor.x = 6;
    try paint(session);
    try std.testing.expectEqual(@as(usize, 2), renderer.repainted_cells);
    try expectLigature(session, .{ 2, 1 }, "->");

    // Selecting half of the ligature shows its characters; selecting both keeps it.
    var projection = session.gui.projection();
    projection.copy = .{ .pane_id = target.id, .view = .{ .cursor = .{ .x = 3, .y = 1 }, .anchor = .{ .x = 3, .y = 1 }, .linewise = false, .pointer = true } };
    _ = try renderer.prepare(projection);
    try std.testing.expectEqual(@as(usize, 2), renderer.repainted_cells);
    var storage: [CellMesh.capacity]Quad = undefined;
    const area = content(session);
    const selected = renderer.retained.at(.{ area.x + 3, area.y + 1 }).collect(&storage)[1..];
    try std.testing.expectEqual(alone.items()[0].u0, selected[0].u0);
    projection.copy.?.view.anchor = .{ .x = 2, .y = 1 };
    _ = try renderer.prepare(projection);
    var whole = try shapedTogether(session, .{ 2, 1 }, "->");
    defer whole.deinit();
    var drawn = try retainedInk(session, .{ 2, 1 }, 2);
    defer drawn.deinit();
    try std.testing.expectEqual(whole.items().len, drawn.items().len);
    try std.testing.expectEqual(whole.items()[0].u0, drawn.items()[0].u0);
    try std.testing.expectEqual(renderer.background.r, drawn.items()[0].r);
}

test "ordinary text draws exactly as cell by cell and warm frames shape and allocate nothing" {
    const session = try configured();
    defer session.deinit();
    const renderer = &session.gui.renderer;
    const target = pane(session);
    const text = "hello, World 42";
    write(session, .{ 1, 1 }, text);
    write(session, .{ 1, 2 }, "if a != b => c");
    try paint(session);
    try expectAlone(session, .{ 1, 1 }, text);
    try expectLigature(session, .{ 6, 2 }, "!=");
    try expectLigature(session, .{ 11, 2 }, "=>");

    // Warm-up: each edit below shapes its new runs once.
    for (0..2) |_| {
        write(session, .{ 7, 2 }, "-");
        try paint(session);
        write(session, .{ 7, 2 }, "=");
        try paint(session);
    }

    const shape_calls = renderer.atlas.?.shape_calls;
    const version = renderer.atlas.?.version;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    renderer.allocator = failing.allocator();
    renderer.quads.allocator = failing.allocator();
    renderer.cell_quads.allocator = failing.allocator();
    renderer.retained.allocator = failing.allocator();
    renderer.runs.allocator = failing.allocator();
    renderer.atlas.?.allocator = failing.allocator();
    defer {
        renderer.allocator = std.testing.allocator;
        renderer.quads.allocator = std.testing.allocator;
        renderer.cell_quads.allocator = std.testing.allocator;
        renderer.retained.allocator = std.testing.allocator;
        renderer.runs.allocator = std.testing.allocator;
        renderer.atlas.?.allocator = std.testing.allocator;
    }

    for (0..60) |_| {
        try paint(session);
        try std.testing.expectEqual(@as(usize, 0), renderer.repainted_cells);
    }

    for (0..20) |index| {
        write(session, .{ 7, 2 }, if (index % 2 == 0) "-" else "=");
        try paint(session);
        try std.testing.expectEqual(@as(usize, 2), renderer.repainted_cells);
        target.cursor.x = @intCast(index % 4);
        try paint(session);
    }

    try std.testing.expectEqual(shape_calls, renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(version, renderer.atlas.?.version);
    try std.testing.expect(!failing.has_induced_failure);
}

fn configured() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    const config: client.GuiConfig = .{ .font = .{ .size = 22 } };
    const renderer = try Renderer.configured(std.testing.allocator, std.testing.io, .{ .config = config, .viewport = .{ .width = 390, .height = 276, .scale = 1 } });
    session.gui.renderer.deinit();
    session.gui.renderer = renderer;
    const size = try session.gui.renderer.measure(
        .{
            .width = 390,
            .height = 276,
            .scale = 1,
        },
    );
    try session.gui.resize(size, renderer.theme);
    try session.bootstrap();
    try session.receiveFrame(1);
    clear(session);
    return session;
}

fn pane(session: *Session) *data.Pane {
    return session.gui.app.model.panes.find(Session.pane_id).?;
}

fn content(session: *Session) cellgrid.Rect {
    return data.tab_layout.view(&session.gui.app.model, session.gui.app.model.tabs.active, Session.pane_id, data.workbench.region(&session.gui.app.model).area).?.content;
}

// Empties the screen and parks the cursor on the last row, away from the
// cells under test, so it never splits a run there.
fn clear(session: *Session) void {
    const target = pane(session);
    @memset(target.buffer.cells, .{});
    target.cursor = .{ .visible = true, .x = 0, .y = target.buffer.h - 1 };
}

fn write(session: *Session, point: [2]u16, text: []const u8) void {
    const target = pane(session);
    for (text, 0..) |byte, index| {
        const cell = &target.buffer.cells[@as(usize, point[1]) * target.buffer.w + point[0] + index];
        cell.* = .{};
        cell.bytes[0] = byte;
    }
}

fn setText(session: *Session, point: [2]u16, text: []const u8) void {
    const target = pane(session);
    const cell = &target.buffer.cells[@as(usize, point[1]) * target.buffer.w + point[0]];
    cell.* = .{};
    @memcpy(cell.bytes[0..text.len], text);
    cell.len = @intCast(text.len);
}

// The cells starting at `point` draw `text` shaped as one line.
fn expectLigature(session: *Session, point: [2]u16, text: []const u8) !void {
    var whole = try shapedTogether(session, point, text);
    defer whole.deinit();
    var drawn = try retainedInk(session, point, text.len);
    defer drawn.deinit();
    try expectSameGlyphs(whole.items(), drawn.items());
}

// The cells starting at `point` draw `text` exactly as each shapes alone.
fn expectAlone(session: *Session, point: [2]u16, text: []const u8) !void {
    var alone = try shapedAlone(session, point, text);
    defer alone.deinit();
    var drawn = try retainedInk(session, point, text.len);
    defer drawn.deinit();
    try std.testing.expectEqual(alone.items().len, drawn.items().len);
    for (alone.items(), drawn.items()) |expected, actual| {
        var colored = expected;
        colored.r = actual.r;
        colored.g = actual.g;
        colored.b = actual.b;
        colored.a = actual.a;
        try std.testing.expectEqualDeep(colored, actual);
    }
}

// Retained meshes reproduce a frame drawn from nothing.
fn expectRedrawMatches(session: *Session) !void {
    const renderer = &session.gui.renderer;
    try paint(session);
    const retained = try std.testing.allocator.dupe(Quad, renderer.quads.items());
    defer std.testing.allocator.free(retained);
    renderer.retained.invalidate();
    try paint(session);
    try std.testing.expectEqualSlices(Quad, renderer.quads.items(), retained);
}

fn paint(session: *Session) !void {
    _ = try session.gui.renderer.prepare(session.gui.projection());
    session.gui.renderer.seal();
}

fn cellRect(session: *Session, point: [2]u16) gfx.Rect {
    const renderer = &session.gui.renderer;
    const area = content(session);
    return renderer.metrics.rect(renderer.origin, .{ .x = area.x + point[0], .y = area.y + point[1], .w = 1, .h = 1 });
}

// The glyphs the atlas places when it shapes `text` as one line from the
// first cell's pen: the reference a ligature-aware grid must reproduce.
fn shapedTogether(session: *Session, point: [2]u16, text: []const u8) !QuadList {
    var list = QuadList.init(std.testing.allocator);
    errdefer list.deinit();
    const renderer = &session.gui.renderer;
    const rect = cellRect(session, point);
    _ = try renderer.atlas.?.place(.{ .text = text, .x = rect.x, .y = rect.y + renderer.metrics.baseline, .color = renderer.foreground, .pixel_height = renderer.metrics.pixel_height, .cell_bounds = renderer.metrics.glyphCell() }, &list);
    return list;
}

// Each cell of `text` placed alone with its own synthetic style.
fn shapedAlone(session: *Session, point: [2]u16, text: []const u8) !QuadList {
    var list = QuadList.init(std.testing.allocator);
    errdefer list.deinit();
    const renderer = &session.gui.renderer;
    const target = pane(session);
    for (0..text.len) |index| {
        const col = point[0] + @as(u16, @intCast(index));
        const style = target.buffer.cells[@as(usize, point[1]) * target.buffer.w + col].style;
        const rect = cellRect(session, .{ col, point[1] });
        _ = try renderer.atlas.?.place(.{ .text = text[index..][0..1], .x = rect.x, .y = rect.y + renderer.metrics.baseline, .color = renderer.foreground, .pixel_height = renderer.metrics.pixel_height, .cell_bounds = renderer.metrics.glyphCell(), .bold = style.flags.bold, .italic = style.flags.italic }, &list);
    }

    return list;
}

// Every retained glyph of `len` cells in order, without backgrounds or lines.
fn retainedInk(session: *Session, point: [2]u16, len: usize) !QuadList {
    var list = QuadList.init(std.testing.allocator);
    errdefer list.deinit();
    const renderer = &session.gui.renderer;
    const area = content(session);
    var storage: [CellMesh.capacity]Quad = undefined;
    for (0..len) |index| {
        const mesh = renderer.retained.at(.{ area.x + point[0] + @as(u16, @intCast(index)), area.y + point[1] });
        for (mesh.collect(&storage)[1..]) |quad| {
            if (quad.u0 == gfx.Quad.solid_uv[0] and quad.v0 == gfx.Quad.solid_uv[1]) {
                continue;
            }

            try list.push(quad);
        }
    }

    return list;
}
