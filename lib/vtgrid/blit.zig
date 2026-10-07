const cellgrid = @import("cellgrid");
const std = @import("std");
const vt = @import("ghostty-vt");

// Copying an emulated screen into our cell grid.
//
// This is the only file that knows both halves, and that is deliberate. `ui`
// draws chrome and knows nothing about terminals; `vt` emulates terminals and
// knows nothing about our grid. Keeping the translation in one adapter is what
// lets the drawing layer be lifted out later without dragging an emulator
// behind it.
//
// `vt.RenderState` walks the page list, resolves styles into runs, duplicates
// grapheme data out of pages that may be freed, and tracks which rows changed.
// It retains buffers between frames so a steady state allocates nothing. Its
// `beginUpdate` needs the terminal and `endUpdate` does not, so the actor owning
// the pty can be released before the copying starts. This file turns the
// result into cells.
//
// What it must get right, and what a naive copy gets wrong:
//
//   - Unmodified defaults and palette entries stay semantic, so the outer
//     terminal applies the user's theme. OSC 4/10/11 overrides become RGB here
//     because they belong to this pane and must not leak into another one.
//   - A wide character owns two columns and the emulator marks the second one
//     `spacer_tail`. Emitting anything there prints half a glyph twice.

/// Copies the viewport of `state` into `area` of `b`.
///
/// `state` must have completed an `endUpdate`. Rows the emulator did not mark
/// dirty are left untouched, which is what makes a mostly-still pane nearly
/// free; the row flags are cleared as they are consumed, so a second blit with
/// no intervening update copies nothing.
///
/// ```zig
/// _ = blit(.{ .buffer = buffer, .area = area, .terminal = terminal, .state = state, .options = options });
/// ```
pub fn blit(operation: Operation) Stats {
    const b = operation.buffer;
    const area = operation.area;
    const terminal = operation.terminal;
    const state = operation.state;
    const opts = operation.options;
    const color_source: ColorSource = .{ .terminal = terminal, .colors = state.colors };
    const default_style = defaultStyle(&color_source);

    var stats: Stats = .{};
    if (opts.damaged_rows) |damaged| {
        std.debug.assert(damaged.len >= b.h);
    }

    // `full` means global state moved - the palette, the default colours, the
    // dimensions - and the per-row flags say nothing useful about that.
    const all = opts.force or state.dirty == .full;

    // Consuming the flag is the caller's job, and forgetting it is silent: the
    // state stays `full` forever, every row is copied every frame, and the only
    // symptom is that the renderer is slow. Clearing it here means one blit
    // owns one render state, which is telar's arrangement anyway - a pane is
    // drawn once per frame.
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
        const target: RowTarget = .{ .buffer = b, .area = area, .y = y };
        blitRow(&.{ .target = target, .cells = row_cells[y].slice(), .colors = color_source }, default_style);
        if (opts.selection) |range| {
            highlightRow(target, range);
        }
        dirty[y] = false;
        if (opts.damaged_rows) |damaged| {
            damaged[area.y + y] = true;
        }
        stats.copied += 1;
    }

    // Rows the pane does not have. A pane shorter than its rectangle happens
    // during a resize, and leaving the previous tenant's pixels there reads as
    // a rendering bug.
    while (y < area.h) : (y += 1) {
        b.fill(area.row(y), .{ .glyph = " ", .style = .{ .bg = default_style.bg } });
        if (opts.damaged_rows) |damaged| {
            damaged[area.y + y] = true;
        }
    }

    // Applied after the rows, and to *every* row rather than only the dirty
    // ones: dragging a selection changes which cells are highlighted without
    // changing a single character, so the emulator marks nothing dirty at all.
    if (opts.selection) |range| {
        var row: u16 = 0;
        while (row < height) : (row += 1) {
            if (!all and !dirty[row]) {
                highlightRow(.{ .buffer = b, .area = area, .y = row }, range);
            }
        }
    }

    if (opts.cursor) {
        drawCursor(b, area, state);
    }
    return stats;
}

fn highlightRow(target: RowTarget, range: cellgrid.SelectionRange) void {
    const b = target.buffer;
    const area = target.area;
    const y = target.y;

    var x: u16 = 0;
    while (x < area.w) : (x += 1) {
        if (!range.contains(x, y)) {
            continue;
        }
        // Reversed rather than a fixed colour: a pane paints its own
        // background, and a highlight that picks one loses the contrast the
        // moment an agent changes theme.
        if (b.at(area.x + x, area.y + y)) |cell| {
            cell.style.flags.inverse = !cell.style.flags.inverse;
        }
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
///
/// ```zig
/// const text = try selectionText(gpa, terminal, range);
/// ```
pub fn selectionText(gpa: std.mem.Allocator, terminal: *vt.Terminal, range: cellgrid.SelectionRange) ![:0]const u8 {
    const from, const to = range.ordered();
    const s = terminal.screens.active;

    const start = s.pages.pin(.{ .viewport = .{ .x = from.x, .y = from.y } }) orelse
        return error.OutOfBounds;
    const finish = s.pages.pin(.{ .viewport = .{ .x = to.x, .y = to.y } }) orelse
        return error.OutOfBounds;

    const selection: vt.Selection = .init(start, finish, range.mode == .block);
    return s.selectionString(gpa, .{ .sel = selection, .trim = true });
}

fn blitRow(projection: *const RowProjection, default_style: cellgrid.Style) void {
    const b = projection.target.buffer;
    const area = projection.target.area;
    const y = projection.target.y;
    const cells = projection.cells;
    const colors = &projection.colors;

    const raws = cells.items(.raw);
    const styles = cells.items(.style);
    const graphemes = cells.items(.grapheme);

    const width = @min(area.w, @as(u16, @intCast(cells.len)));

    // When the whole row segment is inside the clip, ASCII cells are stored
    // straight into the row instead of going through `setCell`, which would
    // re-check the clip and copy one byte through a length-generic memcpy.
    const destination_y = area.y + y;
    const direct: ?[]cellgrid.Cell = if (width != 0 and b.clip.contains(area.x, destination_y) and b.clip.contains(area.x + width - 1, destination_y))
        b.cells[@as(usize, destination_y) * b.w + area.x ..][0..width]
    else
        null;

    // A row lives in one emulator page, so one style id names one style for
    // the whole row. Runs of equally styled cells translate their colours once.
    var translated_id: ?@TypeOf(raws[0].style_id) = null;
    var translated: cellgrid.Style = default_style;
    var x: u16 = 0;
    while (x < width) : (x += 1) {
        const raw = raws[x];

        // Style id zero is the default style and the emulator does not fill
        // `style` for it, so reading it unconditionally is reading undefined
        // memory.
        if (raw.style_id != 0 and translated_id != raw.style_id) {
            translated = translate(styles[x], colors, default_style);
            translated_id = raw.style_id;
        }

        std.debug.assert(raw.style_id == 0 or std.meta.eql(translated, translate(styles[x], colors, default_style)));
        const style = if (raw.style_id == 0) default_style else translated;

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
                b.setCell(.{ .x = area.x + x, .y = area.y + y }, .{ .text = " ", .width = 1, .style = style });
                continue;
            },

            .narrow, .wide => {},
        }

        const cell_width: u8 = if (raw.wide == .wide) 2 else 1;

        switch (raw.content_tag) {
            .codepoint, .codepoint_grapheme => {
                const base = raw.codepoint();
                if (direct) |row| {
                    if (raw.content_tag == .codepoint and cell_width == 1 and base > 0 and base < 0x80) {
                        row[x] = asciiCell(@intCast(base), style);
                        continue;
                    }
                }

                var utf8: [cellgrid.Cell.max_bytes]u8 = undefined;
                const text = encode(&utf8, base, if (raw.content_tag == .codepoint_grapheme)
                    graphemes[x]
                else
                    &.{});
                b.setCell(.{ .x = area.x + x, .y = area.y + y }, .{ .text = text, .width = cell_width, .style = style });
            },

            // A cell with a background and no text. The emulator stores these
            // without a style entry precisely because they are common, so the
            // colour comes off the cell itself.
            .bg_color_palette => b.setCell(.{ .x = area.x + x, .y = area.y + y }, .{ .text = " ", .width = 1, .style = .{
                .bg = paletteColor(colors, raw.content.color_palette.data),
            } }),
            .bg_color_rgb => {
                const c = raw.content.color_rgb;
                b.setCell(.{ .x = area.x + x, .y = area.y + y }, .{ .text = " ", .width = 1, .style = .{ .bg = .rgb(.{ c.r, c.g, c.b }) } });
            },
        }
    }

    // Columns the pane does not reach.
    var pad = width;
    while (pad < area.w) : (pad += 1) {
        b.setCell(.{ .x = area.x + pad, .y = area.y + y }, .{ .text = " ", .width = 1, .style = .{
            .bg = default_style.bg,
        } });
    }
}

/// The cell `Buffer.setCell` writes for one printable ASCII byte.
fn asciiCell(byte: u8, style: cellgrid.Style) cellgrid.Cell {
    var cell: cellgrid.Cell = .{
        .len = 1,
        .width = 1,
        .style = style,
    };
    cell.bytes[0] = byte;
    return cell;
}

/// Encodes a grapheme cluster as UTF-8.
///
/// `raw.codepoint()` is the base and `extra` holds only what follows it, so a
/// cluster is the concatenation rather than either one alone. A cluster longer
/// than a cell is truncated at a codepoint boundary: a family emoji renders
/// short, which is a visual defect, where a truncated code unit is mojibake.
fn encode(out: *[cellgrid.Cell.max_bytes]u8, base: u21, extra: []const u21) []const u8 {
    // A cell the emulator never wrote holds codepoint zero, which is not a
    // character. Blanking it here keeps NUL out of the output stream.
    if (base == 0) {
        return " ";
    }

    var len: usize = std.unicode.utf8Encode(base, out) catch return "\u{FFFD}";
    for (extra) |cp| {
        const remaining = out[len..];
        if (remaining.len < 4) {
            break;
        }
        len += std.unicode.utf8Encode(cp, remaining) catch break;
    }
    return out[0..len];
}

/// Turns an emulator style into one of ours, resolving every colour.
///
/// The attribute word is reinterpreted rather than copied field by field;
/// `ui.Style.Flags` is declared to match it and a test in `ui.zig` fails if a
/// libghostty-vt update moves a bit.
fn translate(style: vt.Style, colors: *const ColorSource, default_style: cellgrid.Style) cellgrid.Style {
    return .{
        .fg = resolve(style.fg_color, colors, default_style.fg),
        .bg = resolve(style.bg_color, colors, default_style.bg),
        // Underline colour has no default of its own: unset means "use the
        // foreground", which the terminal already does when SGR 58 is absent.
        .underline_color = switch (style.underline_color) {
            .none => .default,
            else => resolve(style.underline_color, colors, default_style.fg),
        },
        .flags = @bitCast(@as(u16, @bitCast(style.flags))),
    };
}

/// Resolves a colour to concrete channels using the *pane's* palette.
///
/// Passing an index through instead would let the outer terminal answer with
/// its own palette, so an agent that recoloured its terminal would render in
/// whatever the user's theme happens to map that slot to.
fn resolve(c: vt.Style.Color, colors: *const ColorSource, default_color: cellgrid.Color) cellgrid.Color {
    return switch (c) {
        .none => default_color,
        .palette => |i| paletteColor(colors, i),
        .rgb => |v| rgb(v),
    };
}

// Defaults and reverse mode are constant during a blit. Resolve them once so
// every default cell, explicit style and padding cell shares the same frame.
fn defaultStyle(source: *const ColorSource) cellgrid.Style {
    if (source.terminal.modes.get(.reverse_colors)) {
        return .{
            .fg = rgb(source.colors.foreground),
            .bg = rgb(source.colors.background),
        };
    }

    return .{
        .fg = if (source.terminal.colors.foreground.override) |color| rgb(color) else .default,
        .bg = if (source.terminal.colors.background.override) |color| rgb(color) else .default,
    };
}

fn paletteColor(source: *const ColorSource, index: u8) cellgrid.Color {
    if (source.terminal.colors.palette.mask.isSet(index)) {
        return rgb(source.colors.palette[index]);
    }

    return .indexed(index);
}

fn rgb(c: vt.color.RGB) cellgrid.Color {
    return .rgb(.{ c.r, c.g, c.b });
}

/// Marks the cursor by swapping the cell's colours.
///
/// Reversing rather than painting a block keeps whatever character is under it
/// legible, and costs no knowledge of the pane's theme.
fn drawCursor(b: *cellgrid.Buffer, area: cellgrid.Rect, state: *const vt.RenderState) void {
    if (!state.cursor.visible) {
        return;
    }
    const viewport = state.cursor.viewport orelse return;
    if (viewport.x >= area.w or viewport.y >= area.h) {
        return;
    }

    const cell = b.at(area.x + viewport.x, area.y + viewport.y) orelse return;
    cell.style.flags.inverse = !cell.style.flags.inverse;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Operation = struct {
    buffer: *cellgrid.Buffer,
    area: cellgrid.Rect,
    terminal: *const vt.Terminal,
    state: *vt.RenderState,
    options: Options,
};

const RowProjection = struct {
    target: RowTarget,
    cells: std.MultiArrayList(vt.RenderState.Cell).Slice,
    colors: ColorSource,
};

const ColorSource = struct {
    terminal: *const vt.Terminal,
    colors: vt.RenderState.Colors,
};

const RowTarget = struct {
    buffer: *cellgrid.Buffer,
    area: cellgrid.Rect,
    y: u16,
};

const Options = struct {
    /// Cells to draw as selected, in coordinates relative to `area`.
    ///
    /// Passed in rather than read off the render state because the gesture
    /// belongs to the model: the emulator has a selection concept, but
    /// which drag the user is making, and whether it is even aimed at this
    /// pane, is not something it can know.
    selection: ?cellgrid.SelectionRange = null,

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

const Stats = struct {
    /// Rows whose cells were translated.
    copied: u16 = 0,
    /// Rows skipped because neither the emulator nor the caller marked them.
    skipped: u16 = 0,
};
