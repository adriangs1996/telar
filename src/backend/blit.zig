const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const ui = core.ui;
const sel = core.select;

// Copying an emulated screen into our cell grid.
//
// This is the only file that knows both halves, and that is deliberate. `ui`
// draws chrome and knows nothing about terminals; `vt` emulates terminals and
// knows nothing about our grid. Keeping the translation in one adapter is what
// lets the drawing layer be lifted out later without dragging an emulator
// behind it.
//
// The expensive half of the work is not here. `vt.RenderState` already walks
// the page list, resolves styles into runs, duplicates grapheme data out of
// pages that may be freed, tracks which rows changed, and retains its buffers
// between frames so a steady state allocates nothing. It also splits into
// `beginUpdate` (needs the terminal) and `endUpdate` (does not), so the actor
// owning the pty can be released before the copying starts. All this file does
// is turn that into cells.
//
// What it must get right, and what a naive copy gets wrong:
//
//   - Unmodified defaults and palette entries stay semantic, so the outer
//     terminal applies the user's theme. OSC 4/10/11 overrides become RGB here
//     because they belong to this pane and must not leak into another one.
//   - A wide character owns two columns and the emulator marks the second one
//     `spacer_tail`. Emitting anything there prints half a glyph twice.

pub const Options = struct {
    /// Cells to draw as selected, in coordinates relative to `area`.
    ///
    /// Passed in rather than read off the render state because the gesture
    /// belongs to the application: the emulator has a selection concept, but
    /// which drag the user is making, and whether it is even aimed at this
    /// pane, is not something it can know.
    selection: ?sel.Range = null,

    /// Draw the pane's cursor. Off for unfocused panes: two visible cursors in
    /// one screen is worse than none, and the real cursor is placed by `term`.
    cursor: bool = false,

    /// Copy every row regardless of its dirty flag.
    ///
    /// Needed whenever the destination changed without the source changing -
    /// the pane moved, the window resized, a modal that covered it closed -
    /// because the emulator has no idea any of that happened.
    force: bool = false,

    /// Destination rows copied by this blit.
    ///
    /// A runtime can retain this slice until it builds a frame, then compare
    /// only the rows which may have changed. The slice belongs to the caller
    /// and must cover the destination buffer's height. Marks accumulate so
    /// several blits can be folded without losing earlier damage.
    damaged_rows: ?[]bool = null,
};

pub const Stats = struct {
    /// Rows whose cells were translated.
    copied: u16 = 0,
    /// Rows skipped because neither the emulator nor the caller marked them.
    skipped: u16 = 0,
};

/// Copies the viewport of `state` into `area` of `b`.
///
/// `state` must have completed an `endUpdate`. Rows the emulator did not mark
/// dirty are left untouched, which is what makes a mostly-still pane nearly
/// free; the row flags are cleared as they are consumed, so a second blit with
/// no intervening update copies nothing.
pub fn blit(
    b: *ui.Buffer,
    area: ui.Rect,
    terminal: *const vt.Terminal,
    state: *vt.RenderState,
    opts: Options,
) Stats {
    var stats: Stats = .{};
    if (opts.damaged_rows) |damaged| std.debug.assert(damaged.len >= b.h);

    // `full` means global state moved - the palette, the default colours, the
    // dimensions - and the per-row flags say nothing useful about that.
    const all = opts.force or state.dirty == .full;

    // Consuming the flag is the caller's job, and forgetting it is silent: the
    // state stays `full` forever, every row is copied every frame, and the only
    // symptom is that the renderer is slow. Clearing it here means one blit
    // owns one render state, which is the arrangement herdr has anyway - a pane
    // is drawn once per frame.
    state.dirty = .false;

    const rows = state.row_data.slice();
    const dirty = rows.items(.dirty);
    const row_cells = rows.items(.cells);

    const height = @min(area.h, @as(u16, @intCast(rows.len)));
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        if (!all and !dirty[y]) {
            stats.skipped += 1;
            continue;
        }
        blitRow(b, area, y, row_cells[y].slice(), terminal, state.colors);
        if (opts.selection) |range| highlightRow(b, area, y, range);
        dirty[y] = false;
        if (opts.damaged_rows) |damaged| damaged[area.y + y] = true;
        stats.copied += 1;
    }

    // Rows the pane does not have. A pane shorter than its rectangle happens
    // during a resize, and leaving the previous tenant's pixels there reads as
    // a rendering bug.
    while (y < area.h) : (y += 1) {
        b.fill(area.row(y), " ", .{ .bg = defaultBackground(terminal, state.colors) });
        if (opts.damaged_rows) |damaged| damaged[area.y + y] = true;
    }

    // Applied after the rows, and to *every* row rather than only the dirty
    // ones: dragging a selection changes which cells are highlighted without
    // changing a single character, so the emulator marks nothing dirty at all.
    if (opts.selection) |range| {
        var row: u16 = 0;
        while (row < height) : (row += 1) {
            if (!all and !dirty[row]) highlightRow(b, area, row, range);
        }
    }

    if (opts.cursor) drawCursor(b, area, state);
    return stats;
}

fn highlightRow(b: *ui.Buffer, area: ui.Rect, y: u16, range: sel.Range) void {
    var x: u16 = 0;
    while (x < area.w) : (x += 1) {
        if (!range.contains(x, y)) continue;
        // Reversed rather than a fixed colour: a pane paints its own
        // background, and a highlight that picks one loses the contrast the
        // moment an agent changes theme.
        if (b.at(area.x + x, area.y + y)) |cell| cell.style.flags.inverse = !cell.style.flags.inverse;
    }
}

/// The selected text, as the emulator understands it.
///
/// This is the whole reason a pane does not use `select.text`. Reading our own
/// cells gives back what is *painted*, and a line the emulator wrapped at the
/// pane's width comes out with a newline in the middle that was never in the
/// agent's output. `selectionString` unwraps those, because the emulator is the
/// only thing that knows which breaks it invented.
///
/// The caller frees the result.
pub fn selectionText(
    gpa: std.mem.Allocator,
    terminal: *vt.Terminal,
    range: sel.Range,
) ![:0]const u8 {
    const from, const to = range.ordered();
    const s = terminal.screens.active;

    const start = s.pages.pin(.{ .viewport = .{ .x = from.x, .y = from.y } }) orelse
        return error.OutOfBounds;
    const finish = s.pages.pin(.{ .viewport = .{ .x = to.x, .y = to.y } }) orelse
        return error.OutOfBounds;

    const selection: vt.Selection = .init(start, finish, range.mode == .block);
    return s.selectionString(gpa, .{ .sel = selection, .trim = true });
}

fn blitRow(
    b: *ui.Buffer,
    area: ui.Rect,
    y: u16,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    terminal: *const vt.Terminal,
    colors: vt.RenderState.Colors,
) void {
    const raws = cells.items(.raw);
    const styles = cells.items(.style);
    const graphemes = cells.items(.grapheme);

    const width = @min(area.w, @as(u16, @intCast(cells.len)));
    var x: u16 = 0;
    while (x < width) : (x += 1) {
        const raw = raws[x];

        // Style id zero is the default style and the emulator does not fill
        // `style` for it, so reading it unconditionally is reading undefined
        // memory.
        const style = translate(
            if (raw.style_id == 0) .{} else styles[x],
            terminal,
            colors,
        );

        switch (raw.wide) {
            // The emulator's own marker for the column a wide glyph continues
            // into. Our grid uses width zero for the same thing, and
            // `setGraphemeAt` already wrote it when it placed the head - but a
            // dirty row is copied left to right, so the head has been written
            // by the time we get here and overwriting it would undo that.
            .spacer_tail => continue,

            // A wide glyph did not fit before a soft wrap. There is no
            // character to draw, only a column to keep blank.
            .spacer_head => {
                b.setCell(area.x + x, area.y + y, " ", 1, style);
                continue;
            },

            .narrow, .wide => {},
        }

        const cell_width: u8 = if (raw.wide == .wide) 2 else 1;

        switch (raw.content_tag) {
            .codepoint, .codepoint_grapheme => {
                var utf8: [ui.Cell.max_bytes]u8 = undefined;
                const text = encode(&utf8, raw.codepoint(), if (raw.content_tag == .codepoint_grapheme)
                    graphemes[x]
                else
                    &.{});
                b.setCell(area.x + x, area.y + y, text, cell_width, style);
            },

            // A cell with a background and no text. The emulator stores these
            // without a style entry precisely because they are common, so the
            // colour comes off the cell itself.
            .bg_color_palette => b.setCell(area.x + x, area.y + y, " ", 1, .{
                .bg = paletteColor(terminal, colors, raw.content.color_palette.data),
            }),
            .bg_color_rgb => {
                const c = raw.content.color_rgb;
                b.setCell(area.x + x, area.y + y, " ", 1, .{ .bg = .{ .rgb = .{ c.r, c.g, c.b } } });
            },
        }
    }

    // Columns the pane does not reach.
    var pad = width;
    while (pad < area.w) : (pad += 1) {
        b.setCell(area.x + pad, area.y + y, " ", 1, .{
            .bg = defaultBackground(terminal, colors),
        });
    }
}

/// Encodes a grapheme cluster as UTF-8.
///
/// `raw.codepoint()` is the base and `extra` holds only what follows it, so a
/// cluster is the concatenation rather than either one alone. A cluster longer
/// than a cell is truncated at a codepoint boundary: a family emoji renders
/// short, which is a visual defect, where a truncated code unit is mojibake.
fn encode(out: *[ui.Cell.max_bytes]u8, base: u21, extra: []const u21) []const u8 {
    // A cell the emulator never wrote holds codepoint zero, which is not a
    // character. Blanking it here keeps NUL out of the output stream.
    if (base == 0) return " ";

    var len: usize = std.unicode.utf8Encode(base, out) catch return "\u{FFFD}";
    for (extra) |cp| {
        const remaining = out[len..];
        if (remaining.len < 4) break;
        len += std.unicode.utf8Encode(cp, remaining) catch break;
    }
    return out[0..len];
}

/// Turns an emulator style into one of ours, resolving every colour.
///
/// The attribute word is reinterpreted rather than copied field by field;
/// `ui.Style.Flags` is declared to match it and a test in `ui.zig` fails if a
/// libghostty-vt update moves a bit.
fn translate(
    style: vt.Style,
    terminal: *const vt.Terminal,
    colors: vt.RenderState.Colors,
) ui.Style {
    return .{
        .fg = resolve(style.fg_color, terminal, colors, .foreground),
        .bg = resolve(style.bg_color, terminal, colors, .background),
        // Underline colour has no default of its own: unset means "use the
        // foreground", which the terminal already does when SGR 58 is absent.
        .underline_color = switch (style.underline_color) {
            .none => .default,
            else => resolve(style.underline_color, terminal, colors, .foreground),
        },
        .flags = @bitCast(@as(u16, @bitCast(style.flags))),
    };
}

/// Resolves a colour to concrete channels using the *pane's* palette.
///
/// Passing an index through instead would let the outer terminal answer with
/// its own palette, so an agent that recoloured its terminal would render in
/// whatever the user's theme happens to map that slot to.
const DefaultColor = enum { foreground, background };

fn resolve(
    c: vt.Style.Color,
    terminal: *const vt.Terminal,
    colors: vt.RenderState.Colors,
    default_color: DefaultColor,
) ui.Color {
    return switch (c) {
        .none => switch (default_color) {
            .foreground => defaultForeground(terminal, colors),
            .background => defaultBackground(terminal, colors),
        },
        .palette => |i| paletteColor(terminal, colors, i),
        .rgb => |v| rgb(v),
    };
}

fn defaultForeground(terminal: *const vt.Terminal, colors: vt.RenderState.Colors) ui.Color {
    if (terminal.modes.get(.reverse_colors)) return rgb(colors.foreground);
    return if (terminal.colors.foreground.override) |color| rgb(color) else .default;
}

fn defaultBackground(terminal: *const vt.Terminal, colors: vt.RenderState.Colors) ui.Color {
    if (terminal.modes.get(.reverse_colors)) return rgb(colors.background);
    return if (terminal.colors.background.override) |color| rgb(color) else .default;
}

fn paletteColor(
    terminal: *const vt.Terminal,
    colors: vt.RenderState.Colors,
    index: u8,
) ui.Color {
    if (terminal.colors.palette.mask.isSet(index)) return rgb(colors.palette[index]);
    return .{ .indexed = index };
}

fn rgb(c: vt.color.RGB) ui.Color {
    return .{ .rgb = .{ c.r, c.g, c.b } };
}

/// Marks the cursor by swapping the cell's colours.
///
/// Reversing rather than painting a block keeps whatever character is under it
/// legible, and costs no knowledge of the pane's theme.
fn drawCursor(b: *ui.Buffer, area: ui.Rect, state: *const vt.RenderState) void {
    if (!state.cursor.visible) return;
    const viewport = state.cursor.viewport orelse return;
    if (viewport.x >= area.w or viewport.y >= area.h) return;

    const cell = b.at(area.x + viewport.x, area.y + viewport.y) orelse return;
    cell.style.flags.inverse = !cell.style.flags.inverse;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A pane, driven by writing to it the way an agent would.
///
/// No pty and no process: the emulator takes bytes, so a test can produce any
/// screen state a real agent could by writing the same escape sequences.
const Pane = struct {
    term: vt.Terminal,
    state: vt.RenderState,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Pane {
        return .{
            .term = try vt.Terminal.init(testing.io, gpa, .{ .cols = cols, .rows = rows }),
            .state = .empty,
            .gpa = gpa,
        };
    }

    fn deinit(p: *Pane) void {
        p.state.deinit(p.gpa);
        p.term.deinit(p.gpa);
    }

    fn write(p: *Pane, bytes: []const u8) !void {
        var stream = p.term.vtStream();
        defer stream.deinit();
        stream.nextSlice(bytes);
        try p.state.update(p.gpa, &p.term);
    }
};

fn textOf(b: *ui.Buffer, x: u16, y: u16) []const u8 {
    return (b.at(x, y) orelse unreachable).text();
}

test "the attribute word crosses as a bitcast, so its layout must match" {
    // `translate` reinterprets the emulator's attribute word as ours instead
    // of copying it field by field. That is only sound while the two layouts
    // agree, and nothing else in the build would notice if a libghostty-vt
    // update inserted a bit. Setting every attribute at once catches a moved
    // bit as well as a renamed one, because a mismatch shifts everything after
    // the change.
    // `vt.Style.Flags` is not public, but the field that holds it is, so the
    // type is still reachable - and reaching it this way means the test breaks
    // if the field is renamed, too.
    const VtFlags = @TypeOf(@as(vt.Style, undefined).flags);
    try testing.expectEqual(@bitSizeOf(VtFlags), @bitSizeOf(ui.Style.Flags));

    const theirs: VtFlags = .{
        .bold = true,
        .italic = true,
        .faint = true,
        .blink = true,
        .inverse = true,
        .invisible = true,
        .strikethrough = true,
        .overline = true,
        .underline = .curly,
    };
    const ours: ui.Style.Flags = @bitCast(@as(u16, @bitCast(theirs)));

    try testing.expect(ours.bold and ours.italic and ours.faint and ours.blink);
    try testing.expect(ours.inverse and ours.invisible and ours.strikethrough and ours.overline);
    try testing.expectEqual(ui.Style.Underline.curly, ours.underline);
}

test "text lands in the cells the emulator put it in" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 3);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 20, 5);
    defer buf.deinit();

    try pane.write("hola");
    _ = blit(&buf, .{ .x = 2, .y = 1, .w = 10, .h = 3 }, &pane.term, &pane.state, .{});

    // Offset by the rectangle, not written at the origin: a pane is drawn
    // inside a layout, and getting this wrong is invisible until the pane is
    // not at (0,0).
    try testing.expectEqualStrings("h", textOf(&buf, 2, 1));
    try testing.expectEqualStrings("a", textOf(&buf, 5, 1));
}

test "a wide character owns two columns" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    try pane.write("漢字");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    // Width zero is how the diff knows to emit nothing for the trailing half.
    // Emitting there prints the glyph twice and shifts the rest of the row.
    try testing.expectEqual(@as(u8, 2), (buf.at(0, 0).?).width);
    try testing.expectEqual(@as(u8, 0), (buf.at(1, 0).?).width);
    try testing.expectEqual(@as(u8, 2), (buf.at(2, 0).?).width);
    try testing.expectEqualStrings("漢", textOf(&buf, 0, 0));
    try testing.expectEqualStrings("字", textOf(&buf, 2, 0));
}

test "a grapheme cluster stays one cell" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    // The emulator hands back the base codepoint and the joiners separately;
    // reassembling them is this file's job, and dropping the tail turns a
    // composed emoji into a different one.
    try pane.write("👨‍🚀");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    const cell = buf.at(0, 0).?;
    try testing.expect(cell.len > 4);
    try testing.expect(std.mem.indexOf(u8, cell.text(), "\u{200D}") != null);
}

test "attributes survive the crossing" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    // Bold, italic and curly underline: one from each half of the packed word,
    // so a misaligned bitcast cannot pass by accident.
    try pane.write("\x1b[1;3;4:3mx");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    const flags = buf.at(0, 0).?.style.flags;
    try testing.expect(flags.bold);
    try testing.expect(flags.italic);
    try testing.expectEqual(ui.Style.Underline.curly, flags.underline);
}

test "unmodified colours defer to the outer terminal theme" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    try pane.write("\x1b[31mx");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    const styled = buf.at(0, 0).?;
    try testing.expect(styled.style.fg == .indexed);
    try testing.expectEqual(@as(u8, 1), styled.style.fg.indexed);
    try testing.expect(styled.style.bg == .default);
    try testing.expect(buf.at(9, 1).?.style.bg == .default);
}

test "OSC default colour overrides stay inside the pane" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    try pane.write("\x1b]11;rgb:12/34/56\x07x");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});
    try testing.expectEqual(
        ui.Color{ .rgb = .{ 0x12, 0x34, 0x56 } },
        buf.at(0, 0).?.style.bg,
    );

    try pane.write("\x1b]111\x1b\\");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{ .force = true });
    try testing.expect(buf.at(0, 0).?.style.bg == .default);
}

test "palette colours are resolved with the pane's own palette" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    // OSC 4 repaints colour 1 inside this pane only. Passing the index through
    // for the outer terminal to resolve would render the agent's output in
    // whatever the user's theme maps slot 1 to, which is the bug this test
    // exists to prevent.
    try pane.write("\x1b]4;1;rgb:00/ff/00\x07\x1b[31mx");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    switch (buf.at(0, 0).?.style.fg) {
        .rgb => |c| try testing.expectEqual([3]u8{ 0x00, 0xff, 0x00 }, c),
        else => return error.ColourNotResolved,
    }
}

test "clean rows are skipped and the caller can override that" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 4);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 4);
    defer buf.deinit();

    try pane.write("uno\r\ndos\r\n");
    const first = blit(&buf, buf.area(), &pane.term, &pane.state, .{});
    try testing.expect(first.copied > 0);

    // Nothing was written to the pane in between, so a second blit is pure
    // waste. This is the whole reason a still pane costs nothing per frame.
    const second = blit(&buf, buf.area(), &pane.term, &pane.state, .{});
    try testing.expectEqual(@as(u16, 0), second.copied);
    try testing.expectEqual(@as(u16, 4), second.skipped);

    // But the emulator only knows about its own screen. When the destination
    // moved - a resize, a modal closing over the pane - the caller has to say
    // so, because no dirty flag will.
    const forced = blit(&buf, buf.area(), &pane.term, &pane.state, .{ .force = true });
    try testing.expectEqual(@as(u16, 4), forced.copied);
}

test "only the rows that changed are copied" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 4);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 4);
    defer buf.deinit();

    try pane.write("a\r\nb\r\nc\r\n");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    // One character on one row. If this copies the whole pane, an agent
    // printing a spinner costs as much as an agent printing a full screen.
    try pane.write("Z");
    var damaged_rows = [_]bool{false} ** 4;
    const partial = blit(&buf, buf.area(), &pane.term, &pane.state, .{
        .damaged_rows = &damaged_rows,
    });
    try testing.expect(partial.copied < 4);
    try testing.expect(partial.skipped > 0);
    try testing.expectEqual(@as(usize, partial.copied), std.mem.count(bool, &damaged_rows, &.{true}));
}

test "a pane smaller than its rectangle leaves nothing stale behind" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 4, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 5);
    defer buf.deinit();

    // Whatever was on screen before the pane shrank. During a resize the
    // emulator and the layout disagree for a frame or two, and the leftovers
    // read as a rendering bug.
    buf.fill(buf.area(), "#", .{});
    try pane.write("ab");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    try testing.expectEqualStrings("a", textOf(&buf, 0, 0));
    // Past the pane's last column, and past its last row.
    try testing.expectEqualStrings(" ", textOf(&buf, 6, 0));
    try testing.expectEqualStrings(" ", textOf(&buf, 0, 4));
}

test "the cursor inverts the cell it sits on rather than hiding it" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    try pane.write("ab\x1b[1;1H");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{ .cursor = true });

    // The character under the cursor must still be readable, and the cell to
    // its right must be untouched.
    try testing.expectEqualStrings("a", textOf(&buf, 0, 0));
    try testing.expect(buf.at(0, 0).?.style.flags.inverse);
    try testing.expect(!buf.at(1, 0).?.style.flags.inverse);
}

test "an unfocused pane draws no cursor" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 2);
    defer buf.deinit();

    try pane.write("ab\x1b[1;1H");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{ .cursor = false });
    try testing.expect(!buf.at(0, 0).?.style.flags.inverse);
}

test "a pane wider than its rectangle is clipped, not wrapped" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 20, 2);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 20, 4);
    defer buf.deinit();

    try pane.write("0123456789abcdefghij");
    // A rectangle narrower and shorter than the pane.
    _ = blit(&buf, .{ .x = 0, .y = 0, .w = 5, .h = 1 }, &pane.term, &pane.state, .{});

    try testing.expectEqualStrings("4", textOf(&buf, 4, 0));
    // Column five belongs to whatever is drawn next, not to the pane.
    try testing.expectEqualStrings(" ", textOf(&buf, 5, 0));
}

test "a steady frame allocates nothing" {
    // `blit` cannot allocate: it takes no allocator, and in Zig that is a
    // proof rather than a promise. What this test covers is the pipeline
    // around it - `RenderState.update` does take one, and the whole design
    // rests on its claim to retain buffers between frames.
    //
    // The warm-up matters: the first frames legitimately allocate the row
    // storage and the grapheme arenas. What must not allocate is the
    // hundredth frame of an agent printing into a screen it has already sized.
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 40, 12);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 40, 12);
    defer buf.deinit();

    for (0..12) |_| try pane.write("warming the arenas up\r\n");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});

    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var stream = pane.term.vtStream();
    defer stream.deinit();
    for (0..64) |_| {
        stream.nextSlice("steady output\r\n");
        try pane.state.update(failing.allocator(), &pane.term);
        _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{});
    }
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "a selected pane copies the agent's line, not the wrapped one" {
    // The whole reason a pane does not read its text back out of our cells.
    // The emulator broke this line to fit twenty columns; that break was never
    // in the agent's output, and pasting it puts a newline in the middle of a
    // command.
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 20, 4);
    defer pane.deinit();

    const long = "cargo test --workspace --all-features";
    try pane.write(long);

    const copied = try selectionText(gpa, &pane.term, .{
        .anchor = .{ .x = 0, .y = 0 },
        .head = .{ .x = 19, .y = 1 },
    });
    defer gpa.free(copied);

    try testing.expectEqualStrings(long, copied);
    // The specific failure: reading the painted cells would have found one.
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, copied, '\n'));
}

test "a real line break is kept" {
    // The other half of the same claim. Unwrapping everything would join two
    // lines the agent deliberately separated.
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 20, 4);
    defer pane.deinit();
    try pane.write("uno\r\ndos");

    const copied = try selectionText(gpa, &pane.term, .{
        .anchor = .{ .x = 0, .y = 0 },
        .head = .{ .x = 2, .y = 1 },
    });
    defer gpa.free(copied);
    try testing.expectEqualStrings("uno\ndos", copied);
}

test "highlighting a selection does not disturb the characters" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 3);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 3);
    defer buf.deinit();

    try pane.write("hola");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{
        .selection = .{ .anchor = .{ .x = 1, .y = 0 }, .head = .{ .x = 2, .y = 0 } },
    });

    try testing.expectEqualStrings("o", buf.at(1, 0).?.text());
    try testing.expect(buf.at(1, 0).?.style.flags.inverse);
    try testing.expect(buf.at(2, 0).?.style.flags.inverse);
    try testing.expect(!buf.at(0, 0).?.style.flags.inverse);
    try testing.expect(!buf.at(3, 0).?.style.flags.inverse);
}

test "dragging a selection repaints rows the emulator calls clean" {
    // The trap in combining a selection with dirty tracking: moving the mouse
    // changes which cells are highlighted without changing a single character,
    // so the emulator marks nothing dirty and the highlight would freeze where
    // the drag started.
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 4);
    defer pane.deinit();
    var buf = try ui.Buffer.init(gpa, 10, 4);
    defer buf.deinit();

    try pane.write("aaa\r\nbbb\r\nccc");
    _ = blit(&buf, buf.area(), &pane.term, &pane.state, .{
        .selection = .{ .anchor = .{ .x = 0, .y = 0 }, .head = .{ .x = 2, .y = 0 } },
    });
    try testing.expect(!buf.at(1, 1).?.style.flags.inverse);

    // Nothing written to the pane in between: every row is clean.
    const stats = blit(&buf, buf.area(), &pane.term, &pane.state, .{
        .selection = .{ .anchor = .{ .x = 0, .y = 0 }, .head = .{ .x = 2, .y = 1 } },
    });
    try testing.expectEqual(@as(u16, 0), stats.copied);
    try testing.expect(buf.at(1, 1).?.style.flags.inverse);
}

test "a selection outside the pane is refused rather than guessed at" {
    const gpa = testing.allocator;
    var pane = try Pane.init(gpa, 10, 3);
    defer pane.deinit();
    try pane.write("hola");

    try testing.expectError(error.OutOfBounds, selectionText(gpa, &pane.term, .{
        .anchor = .{ .x = 0, .y = 0 },
        .head = .{ .x = 0, .y = 99 },
    }));
}
