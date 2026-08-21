const std = @import("std");
const Io = std.Io;
/// Imported by module name rather than by path so that a build can swap the
/// width tables out. See `unicode.zig`.
const unicode = @import("unicode");

// A terminal UI, from the bottom up.
//
// ratatui is three things stacked, and only the middle one is interesting:
//
//   1. a grid of cells you draw into, with no memory of the terminal
//   2. a diff between the grid you just drew and the one on screen
//   3. widgets, which are only functions that write into a region of (1)
//
// Everything a user experiences as "the UI" is (3), and (3) needs no framework:
// a widget is `fn (buf: *Buffer, area: Rect, ...) void`. What actually has to
// exist is (2), because writing the whole screen every frame is what makes a
// terminal application feel slow. herdr redraws at most every 16ms, and the
// diff is why that budget is enough no matter how much an agent is printing.
//
// The part that quietly sinks hand rolled TUIs is neither: it is knowing how
// many columns a string occupies. That answer arrives through the `unicode`
// module rather than from a table this file owns, so a build decides which
// implementation replies. The default is the emulator that renders the agents'
// output, which is the only answer guaranteed to match what appears on screen.

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

/// A region of the screen. Layout is rectangle arithmetic and nothing else:
/// no tree, no constraint solver, no state. That is worth keeping, because it
/// means layout can be unit tested without a terminal.
pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn contains(r: Rect, x: u16, y: u16) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }

    /// Shrinks by `margin` on every side, saturating rather than underflowing:
    /// a rectangle too small to shrink becomes empty, which draws as nothing.
    pub fn inner(r: Rect, margin: u16) Rect {
        if (r.w <= margin * 2 or r.h <= margin * 2) return .{ .x = r.x, .y = r.y };
        return .{
            .x = r.x + margin,
            .y = r.y + margin,
            .w = r.w - margin * 2,
            .h = r.h - margin * 2,
        };
    }

    /// Splits off `cols` from the left. The remainder is the second half.
    pub fn splitLeft(r: Rect, cols: u16) [2]Rect {
        const taken = @min(cols, r.w);
        return .{
            .{ .x = r.x, .y = r.y, .w = taken, .h = r.h },
            .{ .x = r.x + taken, .y = r.y, .w = r.w - taken, .h = r.h },
        };
    }

    /// Splits off `rows` from the top.
    pub fn splitTop(r: Rect, rows: u16) [2]Rect {
        const taken = @min(rows, r.h);
        return .{
            .{ .x = r.x, .y = r.y, .w = r.w, .h = taken },
            .{ .x = r.x, .y = r.y + taken, .w = r.w, .h = r.h - taken },
        };
    }

    /// Splits off `rows` from the bottom.
    pub fn splitBottom(r: Rect, rows: u16) [2]Rect {
        const taken = @min(rows, r.h);
        return .{
            .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h - taken },
            .{ .x = r.x, .y = r.y + r.h - taken, .w = r.w, .h = taken },
        };
    }

    /// The overlap of two rectangles, empty if they do not touch.
    ///
    /// Nested clips intersect rather than replace: a widget that pushes a clip
    /// bigger than its parent's would otherwise draw straight out of the box
    /// it was handed, which is the escape hatch clipping exists to close.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const right = @min(a.x + a.w, b.x + b.w);
        const bottom = @min(a.y + a.h, b.y + b.h);
        if (right <= x or bottom <= y) return .{ .x = x, .y = y };
        return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
    }

    pub fn isEmpty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }

    pub fn row(r: Rect, index: u16) Rect {
        if (index >= r.h) return .{ .x = r.x, .y = r.y };
        return .{ .x = r.x, .y = r.y + index, .w = r.w, .h = 1 };
    }
};

// ---------------------------------------------------------------------------
// Cells
// ---------------------------------------------------------------------------

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: [3]u8,

    fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |v| b == .indexed and b.indexed == v,
            .rgb => |v| b == .rgb and std.mem.eql(u8, &v, &b.rgb),
        };
    }
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    /// Separate from `fg` since SGR 58. A terminal that does not understand it
    /// underlines in the foreground colour, which is the pre-58 behaviour.
    underline_color: Color = .default,
    flags: Flags = .{},

    /// The on/off attributes, laid out bit for bit like the emulator's.
    ///
    /// The layout is copied rather than approximated so that blitting a pane's
    /// styles is a `@bitCast` instead of a field by field translation, and so
    /// that a cell we draw and a cell the emulator drew can never disagree
    /// about what "bold" means. The test that pins the two layouts together
    /// lives next to the bitcast, in `blit.zig`.
    pub const Flags = packed struct(u16) {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        overline: bool = false,
        underline: Underline = .none,
        _padding: u5 = 0,
    };

    pub const Underline = enum(u3) {
        none = 0,
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };

    /// Runs once per position per frame in the diff, so it is the hottest
    /// comparison in the renderer. Packing the attributes turned five branches
    /// into one integer compare.
    pub fn eql(a: Style, b: Style) bool {
        return @as(u16, @bitCast(a.flags)) == @as(u16, @bitCast(b.flags)) and
            a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            a.underline_color.eql(b.underline_color);
    }
};

/// One screen position.
///
/// The payload is a grapheme cluster, not a codepoint: `é` may be two
/// codepoints and a flag emoji is two more, and all of them occupy one or two
/// columns as a unit. Storing bytes inline keeps `Cell` comparable with a plain
/// equality check, which the diff runs once per position per frame.
pub const Cell = struct {
    /// Enough for a base character with a few combining marks. Longer clusters
    /// - family emoji with several zero width joiners - are truncated, which
    /// costs a rendering artefact rather than a corrupted grid.
    pub const max_bytes = 16;

    bytes: [max_bytes]u8 = [_]u8{' '} ++ [_]u8{0} ** (max_bytes - 1),
    len: u8 = 1,
    /// 0 marks the second half of a wide character. Nothing is emitted for it;
    /// the terminal's own cursor advance covers it.
    width: u8 = 1,
    style: Style = .{},

    pub fn text(c: *const Cell) []const u8 {
        return c.bytes[0..c.len];
    }

    /// The diff calls this once per position per frame, so it is the hottest
    /// comparison in the renderer.
    pub fn eqlPublic(a: *const Cell, b: *const Cell) bool {
        return a.eql(b);
    }

    fn eql(a: *const Cell, b: *const Cell) bool {
        return a.len == b.len and a.width == b.width and
            std.mem.eql(u8, a.text(), b.text()) and a.style.eql(b.style);
    }
};

// ---------------------------------------------------------------------------
// Buffer
// ---------------------------------------------------------------------------

/// A grid to draw into. Knows nothing about the terminal, which is what makes
/// every widget testable: draw into a buffer, then assert on cells.
pub const Buffer = struct {
    cells: []Cell,
    w: u16,
    h: u16,
    gpa: std.mem.Allocator,

    /// Nothing is written outside this. Starts as the whole buffer.
    clip: Rect,
    stack: [max_clip_depth]Rect = undefined,
    depth: u8 = 0,

    /// Base, a pane, a dropdown, a modal, a tooltip inside it. More nesting
    /// than this is a layout that has lost track of itself.
    pub const max_clip_depth = 8;

    pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !Buffer {
        const cells = try gpa.alloc(Cell, @as(usize, w) * @as(usize, h));
        @memset(cells, .{});
        return .{
            .cells = cells,
            .w = w,
            .h = h,
            .gpa = gpa,
            .clip = .{ .w = w, .h = h },
        };
    }

    /// Restricts drawing to the overlap of `r` and the current clip.
    ///
    /// This is what makes a widget unable to damage its neighbours. Passing a
    /// rectangle to a draw function is a *request*; the clip is the part the
    /// widget cannot argue with, which matters most for the things that do not
    /// take a rectangle at all - a pane blit, a long label, a box border.
    ///
    /// Silently ignored past `max_clip_depth`, because the alternative is a
    /// draw path that can fail, and a frame that draws one widget unclipped is
    /// a cosmetic bug where a frame that returns an error is a blank screen.
    pub fn pushClip(b: *Buffer, r: Rect) void {
        if (b.depth == max_clip_depth) return;
        b.stack[b.depth] = b.clip;
        b.depth += 1;
        b.clip = b.clip.intersect(r);
    }

    pub fn popClip(b: *Buffer) void {
        if (b.depth == 0) return;
        b.depth -= 1;
        b.clip = b.stack[b.depth];
    }

    pub fn deinit(b: *Buffer) void {
        b.gpa.free(b.cells);
    }

    pub fn resize(b: *Buffer, w: u16, h: u16) !void {
        const cells = try b.gpa.realloc(b.cells, @as(usize, w) * @as(usize, h));
        b.cells = cells;
        b.w = w;
        b.h = h;
        // The clip described a buffer that no longer exists, and a stale one
        // would silently drop everything drawn outside the old bounds.
        b.clip = .{ .w = w, .h = h };
        b.depth = 0;
        @memset(b.cells, .{});
    }

    pub fn area(b: *const Buffer) Rect {
        return .{ .w = b.w, .h = b.h };
    }

    pub fn at(b: *Buffer, x: u16, y: u16) ?*Cell {
        if (x >= b.w or y >= b.h) return null;
        return &b.cells[@as(usize, y) * @as(usize, b.w) + @as(usize, x)];
    }

    pub fn clear(b: *Buffer, style: Style) void {
        @memset(b.cells, .{ .style = style });
    }

    pub fn fill(b: *Buffer, r: Rect, glyph: []const u8, style: Style) void {
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            var x = r.x;
            while (x < r.x + r.w) : (x += 1) {
                b.setCell(x, y, glyph, 1, style);
            }
        }
    }

    /// Writes one grapheme cluster at an absolute position, unclipped.
    ///
    /// Public because `blit` writes cells the emulator already laid out: it
    /// knows each cluster's width from the pane's own tables and must not have
    /// them measured a second time.
    pub fn setCell(b: *Buffer, x: u16, y: u16, bytes: []const u8, width: u8, style: Style) void {
        if (!b.clip.contains(x, y)) return;

        // A wide glyph occupies the next column whether or not that column is
        // ours to write. Drawing the head alone makes the terminal advance two
        // columns and paint over the neighbour, so the glyph is replaced by a
        // blank that stays inside the clip.
        const fits = width != 2 or b.clip.contains(x + 1, y);
        const text = if (fits) bytes else " ";
        const drawn: u8 = if (fits) width else 1;

        const cell = b.at(x, y) orelse return;
        const len: u8 = @intCast(@min(text.len, Cell.max_bytes));
        cell.* = .{ .len = len, .width = drawn, .style = style };
        @memcpy(cell.bytes[0..len], text[0..len]);

        // The second column of a wide glyph. Width 0 keeps the diff from
        // emitting anything there and keeps a later write from leaving half of
        // a character behind.
        if (drawn == 2) {
            if (b.at(x + 1, y)) |tail| tail.* = .{ .len = 0, .width = 0, .style = style };
        }
    }

    /// Draws `text` at (x, y), clipped to `r`. Returns the columns advanced.
    ///
    /// Iteration is by grapheme cluster, and the width comes from the same
    /// table the build bound to `unicode`, which by default is the one laying
    /// out the agents' own output. Anything else - counting bytes, counting
    /// codepoints, guessing at emoji - drifts from what the terminal actually
    /// does, and a UI whose idea of a column disagrees with the terminal's
    /// smears on the first accented character.
    pub fn writeText(b: *Buffer, r: Rect, x: u16, y: u16, text: []const u8, style: Style) u16 {
        if (y < r.y or y >= r.y + r.h) return 0;

        var column = x;
        const limit = r.x + r.w;
        var it: GraphemeIterator = .{ .bytes = text };

        while (it.next()) |cluster| {
            if (column >= limit) break;
            // A wide glyph that would straddle the edge is dropped rather than
            // cut in half.
            if (cluster.width == 2 and column + 1 >= limit) break;
            if (column >= r.x) b.setCell(column, y, cluster.bytes, cluster.width, style);
            column += cluster.width;
        }
        return column - x;
    }

    /// Draws `text`, appending an ellipsis if it does not fit in `max_width`.
    ///
    /// The ellipsis has to be measured too, and the cut has to land on a
    /// grapheme boundary: truncating by bytes is how a name ending in an accent
    /// turns into a replacement character.
    pub fn writeTruncated(
        b: *Buffer,
        r: Rect,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: u16,
        style: Style,
    ) u16 {
        if (max_width == 0) return 0;
        if (measure(text) <= max_width) return b.writeText(r, x, y, text, style);

        // Measured, not assumed to be one column. It is one in every real
        // table, but reserving a column and then drawing something wider is
        // how a truncation overruns the box it was supposed to fit inside.
        const ellipsis = "\u{2026}";
        const marker = measure(ellipsis);
        // Not even room for the marker. Drawing it alone would say a value was
        // cut without saying anything about the value.
        if (marker >= max_width) return 0;
        const budget = max_width - marker;

        var it: GraphemeIterator = .{ .bytes = text };
        var used: u16 = 0;
        var cut: usize = 0;
        while (it.next()) |cluster| {
            if (used + cluster.width > budget) break;
            used += cluster.width;
            cut = it.index;
        }
        const written = b.writeText(r, x, y, text[0..cut], style);
        return written + b.writeText(r, x + written, y, ellipsis, style);
    }

    /// Draws `text` so that it ends at the right edge of `r`.
    pub fn writeRight(b: *Buffer, r: Rect, y: u16, text: []const u8, style: Style) u16 {
        const width = measure(text);
        if (width > r.w) return b.writeTruncated(r, r.x, y, text, r.w, style);
        return b.writeText(r, r.x + r.w - width, y, text, style);
    }

    /// Draws a box, with an optional title in the top edge.
    pub fn box(b: *Buffer, r: Rect, style: Style, title: ?[]const u8) void {
        if (r.w < 2 or r.h < 2) return;
        const right = r.x + r.w - 1;
        const bottom = r.y + r.h - 1;

        var x = r.x + 1;
        while (x < right) : (x += 1) {
            b.setCell(x, r.y, "─", 1, style);
            b.setCell(x, bottom, "─", 1, style);
        }
        var y = r.y + 1;
        while (y < bottom) : (y += 1) {
            b.setCell(r.x, y, "│", 1, style);
            b.setCell(right, y, "│", 1, style);
        }
        b.setCell(r.x, r.y, "╭", 1, style);
        b.setCell(right, r.y, "╮", 1, style);
        b.setCell(r.x, bottom, "╰", 1, style);
        b.setCell(right, bottom, "╯", 1, style);

        if (title) |t| {
            const inside: Rect = .{ .x = r.x + 2, .y = r.y, .w = r.w -| 4, .h = 1 };
            _ = b.writeText(inside, r.x + 2, r.y, t, style);
        }
    }
};

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

/// What was clickable, and which layer it belonged to.
///
/// Generic over the action so this can live down here rather than in the
/// client: a modal that swallows the clicks underneath it is a property of the
/// layering, not of the modal. A widget cannot implement it - by the time the
/// widget under the modal is asked, the decision has already been made wrong.
///
/// Fixed capacity on purpose. A frame wanting more clickable things than this
/// has a layout problem, and dropping the extras beats allocating on the draw
/// path.
pub fn Hits(comptime Action: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// Base, dropdown, modal, tooltip. Deeper stacks are a UI that has
        /// lost track of what the user is looking at.
        pub const max_layers = 8;

        pub const Entry = struct { rect: Rect, action: Action, layer: u8 };

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        /// Where each layer stops clicks from falling through. Null means the
        /// layer is transparent outside its own registrations, which is what
        /// the base layer and a tooltip both want.
        blocks: [max_layers]?Rect = @splat(null),
        layer: u8 = 0,
        /// The deepest layer opened this frame, so `at` knows where to start.
        top: u8 = 0,

        /// Everything registered this frame, oldest first.
        ///
        /// Exposed because the useful test over a hit registry is an
        /// exhaustiveness one - every variant a UI can produce should appear
        /// somewhere in a drawn frame, and a control that is drawn but never
        /// registered is invisible to every other kind of test.
        pub fn registered(h: *const Self) []const Entry {
            return h.entries[0..h.len];
        }

        pub fn clear(h: *Self) void {
            h.len = 0;
            h.layer = 0;
            h.top = 0;
            h.blocks = @splat(null);
        }

        /// Opens a layer above the current one.
        ///
        /// `swallows` is the region in which this layer answers for every
        /// point, registered or not. A modal passes its own frame, so a click
        /// on its blank interior lands on the modal instead of reaching the
        /// list behind it. Pass null for an overlay that should not steal
        /// clicks it has no control under - a tooltip, a drag ghost.
        pub fn beginLayer(h: *Self, swallows: ?Rect) void {
            if (h.layer + 1 >= max_layers) return;
            h.layer += 1;
            h.top = @max(h.top, h.layer);
            h.blocks[h.layer] = swallows;
        }

        pub fn endLayer(h: *Self) void {
            if (h.layer == 0) return;
            h.layer -= 1;
        }

        pub fn add(h: *Self, rect: Rect, action: Action) void {
            if (h.len == capacity) return;
            if (rect.isEmpty()) return;
            h.entries[h.len] = .{ .rect = rect, .action = action, .layer = h.layer };
            h.len += 1;
        }

        /// What a click at (x, y) hits, if anything.
        ///
        /// Top layer down, and within a layer the newest registration wins -
        /// so a chip drawn over a task row takes the click rather than the row
        /// underneath it. A layer that swallows the point ends the search
        /// there even when it registered nothing at it, which is the whole
        /// difference between an overlay and a modal.
        pub fn at(h: *const Self, x: u16, y: u16) ?Action {
            var layer: i16 = h.top;
            while (layer >= 0) : (layer -= 1) {
                const current: u8 = @intCast(layer);
                var index = h.len;
                while (index > 0) {
                    index -= 1;
                    const entry = h.entries[index];
                    if (entry.layer != current) continue;
                    if (entry.rect.contains(x, y)) return entry.action;
                }
                if (h.blocks[current]) |region| {
                    if (region.contains(x, y)) return null;
                }
            }
            return null;
        }
    };
}

// ---------------------------------------------------------------------------
// Focus
// ---------------------------------------------------------------------------

/// Who has the keyboard.
///
/// The naive version of this is a field on the application saying which dialog
/// is open, and a check for it at the top of every key handler. That survives
/// one overlay. With two it becomes a chain of conditions that has to be
/// repeated identically in every branch, and the bug it produces is a UI that
/// looks focused and does not respond - the worst kind, because nothing is
/// drawn wrong.
///
/// So focus is registered the same way clicks are: while drawing, in a layer.
/// One rule then replaces every one of those checks:
///
///   **Focus lives in the topmost layer that registered anything focusable.**
///
/// A dialog opening takes the keyboard because it opened a layer. A dialog
/// closing gives it back because its layer is gone. Neither is code anybody
/// writes; both fall out of where the controls were registered.
///
/// Registrations are rebuilt every frame and the focused id is not, which is
/// the whole subtlety. `endFrame` is what reconciles them.
pub fn Focus(comptime Id: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const max_layers = 8;

        pub const Entry = struct { id: Id, layer: u8 };

        entries: [capacity]Entry = undefined,
        len: usize = 0,
        layer: u8 = 0,
        top: u8 = 0,

        /// Survives the frame, unlike the registrations.
        current: ?Id = null,

        /// Where focus starts, before the user has moved it.
        ///
        /// Without this, focus lands on whatever happened to draw first, and
        /// drawing order is a layout decision rather than an interaction one.
        /// The concrete damage: a sidebar whose search box is drawn at the top
        /// opens with the keyboard inside a text field, which makes every
        /// single letter shortcut in the application dead until the user
        /// presses Tab - and nothing on screen explains why.
        initial: ?Id = null,
        /// Where focus was when each layer last had it, so dismissing a dialog
        /// returns the keyboard to the control the user left rather than to the
        /// top of the list.
        remembered: [max_layers]?Id = @splat(null),

        pub fn beginFrame(f: *Self) void {
            f.len = 0;
            f.layer = 0;
            f.top = 0;
        }

        pub fn beginLayer(f: *Self) void {
            if (f.layer + 1 >= max_layers) return;
            f.layer += 1;
            f.top = @max(f.top, f.layer);
        }

        pub fn endLayer(f: *Self) void {
            if (f.layer == 0) return;
            f.layer -= 1;
        }

        /// Declares that `id` can hold the keyboard. Order is tab order.
        pub fn register(f: *Self, id: Id) void {
            if (f.len == capacity) return;
            f.entries[f.len] = .{ .id = id, .layer = f.layer };
            f.len += 1;
        }

        /// Reconciles the surviving focus with what was actually drawn.
        ///
        /// Two things go wrong without it, and both look like a dead keyboard:
        /// the focused control stopped being drawn (a dialog closed, a list
        /// scrolled), or a new layer appeared and focus stayed underneath it.
        pub fn endFrame(f: *Self) void {
            if (f.len == 0) {
                f.current = null;
                return;
            }
            if (f.current) |id| {
                if (f.layerOf(id)) |layer| {
                    if (layer == f.top) return;
                    // Focus is valid but buried. Remember where, so closing
                    // whatever covered it puts the keyboard back.
                    f.remembered[layer] = id;
                }
            }
            // Prefer where this layer was left, then the declared starting
            // point, then whatever drew first.
            if (f.remembered[f.top]) |id| {
                if (f.layerOf(id)) |layer| {
                    if (layer == f.top) {
                        f.current = id;
                        return;
                    }
                }
            }
            if (f.initial) |id| {
                if (f.layerOf(id)) |layer| {
                    if (layer == f.top) {
                        f.current = id;
                        return;
                    }
                }
            }
            f.current = f.firstIn(f.top);
        }

        pub fn focused(f: *const Self) ?Id {
            return f.current;
        }

        /// Whether `id` holds the keyboard, for drawing a focus ring.
        pub fn has(f: *const Self, id: Id) bool {
            const current = f.current orelse return false;
            return std.meta.eql(current, id);
        }

        /// Moves focus explicitly - a click on a control, or an action that
        /// puts the keyboard somewhere. Ignored for anything not drawn, so a
        /// stale id cannot strand the keyboard.
        pub fn set(f: *Self, id: Id) void {
            if (f.layerOf(id)) |layer| {
                f.remembered[layer] = id;
                f.current = id;
            }
        }

        pub fn next(f: *Self) void {
            f.step(1);
        }

        pub fn prev(f: *Self) void {
            f.step(-1);
        }

        /// Cycles within the top layer, wrapping.
        ///
        /// Confined to one layer on purpose: tabbing out of a modal into the
        /// list behind it is how a user ends up typing into something they
        /// cannot see.
        fn step(f: *Self, delta: i32) void {
            const count = f.countIn(f.top);
            if (count == 0) return;

            const at = f.indexIn(f.top, f.current) orelse {
                f.current = f.firstIn(f.top);
                return;
            };
            const size: i32 = @intCast(count);
            const moved = @mod(@as(i32, @intCast(at)) + delta + size, size);
            f.current = f.nthIn(f.top, @intCast(moved));
            if (f.current) |id| f.remembered[f.top] = id;
        }

        fn layerOf(f: *const Self, id: Id) ?u8 {
            for (f.entries[0..f.len]) |entry| {
                if (std.meta.eql(entry.id, id)) return entry.layer;
            }
            return null;
        }

        fn countIn(f: *const Self, layer: u8) usize {
            var total: usize = 0;
            for (f.entries[0..f.len]) |entry| {
                if (entry.layer == layer) total += 1;
            }
            return total;
        }

        fn firstIn(f: *const Self, layer: u8) ?Id {
            return f.nthIn(layer, 0);
        }

        fn nthIn(f: *const Self, layer: u8, n: usize) ?Id {
            var seen: usize = 0;
            for (f.entries[0..f.len]) |entry| {
                if (entry.layer != layer) continue;
                if (seen == n) return entry.id;
                seen += 1;
            }
            return null;
        }

        fn indexIn(f: *const Self, layer: u8, id: ?Id) ?usize {
            const wanted = id orelse return null;
            var seen: usize = 0;
            for (f.entries[0..f.len]) |entry| {
                if (entry.layer != layer) continue;
                if (std.meta.eql(entry.id, wanted)) return seen;
                seen += 1;
            }
            return null;
        }
    };
}

/// Columns `text` will occupy once drawn.
///
/// Shares the iterator `writeText` uses, so a measurement and a draw can never
/// disagree - which is what right alignment and truncation both depend on.
pub fn measure(text: []const u8) u16 {
    var total: u16 = 0;
    var it: GraphemeIterator = .{ .bytes = text };
    while (it.next()) |cluster| total += cluster.width;
    return total;
}

/// Splits text into grapheme clusters and reports each one's column width.
///
/// The segmentation is not ours: `unicode.graphemeWidth` consumes a codepoint
/// slice and reports how many codepoints the first cluster spans and how many
/// columns it occupies. Which table answers is a build-time choice, and the
/// default is the emulator's own - herdr draws its chrome next to panes that
/// same emulator laid out, and two disagreeing width tables produce a UI that
/// drifts one column at a time.
pub const GraphemeIterator = struct {
    bytes: []const u8,
    index: usize = 0,

    /// Long enough for a base character with combining marks or an emoji
    /// sequence with a couple of joiners. A cluster longer than this is split,
    /// which costs a rendering artefact and never a wrong byte count.
    const window = 16;

    pub const Cluster = struct {
        bytes: []const u8,
        width: u8,
    };

    pub fn next(it: *GraphemeIterator) ?Cluster {
        if (it.index >= it.bytes.len) return null;

        // Decode a window, remembering where each codepoint began so the
        // cluster's byte length can be recovered from its codepoint length.
        var codepoints: [window]u21 = undefined;
        var offsets: [window + 1]usize = undefined;
        var count: usize = 0;
        var cursor = it.index;
        offsets[0] = cursor;

        while (count < window and cursor < it.bytes.len) {
            const length = std.unicode.utf8ByteSequenceLength(it.bytes[cursor]) catch break;
            if (cursor + length > it.bytes.len) break;
            const codepoint = std.unicode.utf8Decode(it.bytes[cursor..][0..length]) catch break;
            codepoints[count] = codepoint;
            count += 1;
            cursor += length;
            offsets[count] = cursor;
        }

        if (count == 0) {
            // Invalid or truncated UTF-8. Agents print partial writes, so this
            // is a cell to draw, not an error to propagate.
            it.index += 1;
            return .{ .bytes = "\u{FFFD}", .width = 1 };
        }

        const measured = unicode.graphemeWidth(codepoints[0..count]);
        const start = it.index;
        it.index = offsets[measured.len];

        return .{
            .bytes = it.bytes[start..it.index],
            // Control characters measure zero, and a zero width cell cannot be
            // addressed. Anything unprintable becomes one blank column.
            .width = if (measured.width == 0) 1 else @intCast(measured.width),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "rectangles split without overlapping or losing columns" {
    const full: Rect = .{ .w = 80, .h = 24 };
    const left, const right = full.splitLeft(20);

    try testing.expectEqual(@as(u16, 20), left.w);
    try testing.expectEqual(@as(u16, 60), right.w);
    try testing.expectEqual(left.x + left.w, right.x);
    try testing.expectEqual(full.w, left.w + right.w);
}

test "splitting past the edge yields an empty remainder rather than wrapping" {
    // Underflowing u16 here would produce a rectangle 65000 columns wide, and
    // every write into it would look like memory corruption.
    const narrow: Rect = .{ .w = 10, .h = 3 };
    const taken, const rest = narrow.splitLeft(40);
    try testing.expectEqual(@as(u16, 10), taken.w);
    try testing.expectEqual(@as(u16, 0), rest.w);
}

test "text is written by grapheme, not by byte" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Six bytes, three codepoints, three columns.
    const advanced = buf.writeText(buf.area(), 0, 0, "áéí", .{});
    try testing.expectEqual(@as(u16, 3), advanced);
    try testing.expectEqualStrings("á", buf.at(0, 0).?.text());
    try testing.expectEqualStrings("í", buf.at(2, 0).?.text());
}

test "a wide glyph claims the column after it" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const advanced = buf.writeText(buf.area(), 0, 0, "漢字", .{});
    try testing.expectEqual(@as(u16, 4), advanced);
    try testing.expectEqual(@as(u8, 2), buf.at(0, 0).?.width);
    // The trailing half is addressable but draws nothing.
    try testing.expectEqual(@as(u8, 0), buf.at(1, 0).?.width);
    try testing.expectEqual(@as(u8, 2), buf.at(2, 0).?.width);
}

test "a wide glyph is dropped rather than cut in half at the edge" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 3, 1);
    defer buf.deinit();

    // Two columns fit; the second wide glyph does not, and half of one is
    // worse than none of it.
    const advanced = buf.writeText(buf.area(), 0, 0, "漢字", .{});
    try testing.expectEqual(@as(u16, 2), advanced);
    try testing.expectEqualStrings(" ", buf.at(2, 0).?.text());
}

test "writing is clipped to the area, not to the buffer" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const area: Rect = .{ .x = 2, .y = 0, .w = 4, .h = 1 };
    _ = buf.writeText(area, 2, 0, "abcdefgh", .{});

    try testing.expectEqualStrings("a", buf.at(2, 0).?.text());
    try testing.expectEqualStrings("d", buf.at(5, 0).?.text());
    // Past the area, untouched.
    try testing.expectEqualStrings(" ", buf.at(6, 0).?.text());
}

test "invalid utf-8 becomes one cell instead of failing" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();

    // Agents print partial writes; the UI has to survive them.
    const advanced = buf.writeText(buf.area(), 0, 0, "a\xffb", .{});
    try testing.expectEqual(@as(u16, 3), advanced);
    try testing.expectEqualStrings("a", buf.at(0, 0).?.text());
    try testing.expectEqualStrings("b", buf.at(2, 0).?.text());
}

test "truncation lands on a grapheme boundary and leaves room for the ellipsis" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Cutting "booking-flow-copy" by bytes at the same point would be fine, but
    // cutting an accented name would not, so the cut is by cluster either way.
    const written = buf.writeTruncated(buf.area(), 0, 0, "booking-flow-copy", 8, .{});
    try testing.expectEqual(@as(u16, 8), written);
    try testing.expectEqualStrings("\u{2026}", buf.at(7, 0).?.text());
    try testing.expectEqualStrings("b", buf.at(0, 0).?.text());
}

test "truncation never splits a wide glyph" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    // Four columns available, one for the ellipsis, so one wide glyph fits.
    const written = buf.writeTruncated(buf.area(), 0, 0, "漢字漢字", 4, .{});
    try testing.expect(written <= 4);
    try testing.expectEqual(@as(u8, 2), buf.at(0, 0).?.width);
}

test "text that fits is not truncated" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();
    const written = buf.writeTruncated(buf.area(), 0, 0, "main", 10, .{});
    try testing.expectEqual(@as(u16, 4), written);
    try testing.expectEqualStrings(" ", buf.at(4, 0).?.text());
}

test "right aligned text ends at the right edge" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();

    const r: Rect = .{ .x = 0, .y = 0, .w = 20, .h = 1 };
    _ = buf.writeRight(r, 0, "6 tasks", .{});
    try testing.expectEqualStrings("s", buf.at(19, 0).?.text());
    try testing.expectEqualStrings("6", buf.at(13, 0).?.text());
}

test "the diff distinguishes attributes that used to be invisible to it" {
    // Before the flags were packed, `Style` carried bold/dim/reverse and
    // nothing else, so an italic run and an upright one compared equal and the
    // diff skipped the cell. Every attribute the emulator can set has to be
    // able to make two cells differ, or blitted panes render stale.
    const plain: Style = .{};
    inline for (.{ "italic", "blink", "strikethrough", "overline", "invisible" }) |name| {
        var flags: Style.Flags = .{};
        @field(flags, name) = true;
        try testing.expect(!plain.eql(.{ .flags = flags }));
    }
    try testing.expect(!plain.eql(.{ .flags = .{ .underline = .dotted } }));
    try testing.expect(!plain.eql(.{ .underline_color = .{ .rgb = .{ 255, 0, 0 } } }));
}

test "a clip stops a widget damaging its neighbours" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 3);
    defer buf.deinit();
    buf.fill(buf.area(), ".", .{});

    // A label longer than the box it was given. Without a clip the overflow
    // lands on whatever is drawn to the right, and the symptom is a neighbour
    // that flickers only when this one has a long name.
    buf.pushClip(.{ .x = 2, .y = 1, .w = 4, .h = 1 });
    _ = buf.writeText(buf.area(), 2, 1, "abcdefghij", .{});
    buf.popClip();

    try testing.expectEqualStrings("a", buf.at(2, 1).?.text());
    try testing.expectEqualStrings("d", buf.at(5, 1).?.text());
    // One past the clip, and the row above, both untouched.
    try testing.expectEqualStrings(".", buf.at(6, 1).?.text());
    try testing.expectEqualStrings(".", buf.at(2, 0).?.text());
}

test "a nested clip cannot be wider than its parent" {
    // The escape hatch clipping exists to close: a child that asks for more
    // room than it was given would otherwise get it.
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 20, 1);
    defer buf.deinit();
    buf.fill(buf.area(), ".", .{});

    buf.pushClip(.{ .x = 5, .y = 0, .w = 4, .h = 1 });
    buf.pushClip(buf.area()); // asks for everything
    buf.fill(buf.area(), "#", .{});
    buf.popClip();
    buf.popClip();

    try testing.expectEqualStrings(".", buf.at(4, 0).?.text());
    try testing.expectEqualStrings("#", buf.at(5, 0).?.text());
    try testing.expectEqualStrings("#", buf.at(8, 0).?.text());
    try testing.expectEqualStrings(".", buf.at(9, 0).?.text());
}

test "popping restores the parent clip" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();

    buf.pushClip(.{ .x = 0, .y = 0, .w = 2, .h = 1 });
    buf.popClip();
    _ = buf.writeText(buf.area(), 0, 0, "abcdef", .{});
    try testing.expectEqualStrings("f", buf.at(5, 0).?.text());
}

test "a wide glyph cut by the clip becomes a blank, not half a character" {
    // Drawing only the head makes the terminal advance two columns and paint
    // over the neighbour, so the clip would leak by exactly one column - the
    // hardest kind of bleed to notice and the easiest to blame on the font.
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 10, 1);
    defer buf.deinit();
    buf.fill(buf.area(), ".", .{});

    buf.pushClip(.{ .x = 0, .y = 0, .w = 3, .h = 1 });
    buf.setCell(2, 0, "漢", 2, .{});
    buf.popClip();

    try testing.expectEqual(@as(u8, 1), buf.at(2, 0).?.width);
    try testing.expectEqualStrings(" ", buf.at(2, 0).?.text());
    try testing.expectEqualStrings(".", buf.at(3, 0).?.text());
}

test "resizing forgets a clip that described the old buffer" {
    const gpa = testing.allocator;
    var buf = try Buffer.init(gpa, 4, 1);
    defer buf.deinit();

    buf.pushClip(.{ .x = 0, .y = 0, .w = 2, .h = 1 });
    try buf.resize(10, 1);
    // A stale clip here silently drops everything past column two, and the
    // symptom is a window that only half redraws after being made bigger.
    _ = buf.writeText(buf.area(), 0, 0, "abcdefgh", .{});
    try testing.expectEqualStrings("h", buf.at(7, 0).?.text());
}

const TestAction = union(enum) { row: u16, button, dismiss };
const TestHits = Hits(TestAction, 32);

test "within a layer the newest registration wins" {
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 20, .h = 1 }, .{ .row = 3 });
    // A chip drawn on top of the row it belongs to.
    h.add(.{ .x = 5, .y = 0, .w = 4, .h = 1 }, .button);

    try testing.expectEqual(TestAction.button, h.at(6, 0).?);
    try testing.expectEqual(TestAction{ .row = 3 }, h.at(1, 0).?);
}

test "a modal swallows clicks on its blank interior" {
    // The failure this exists to prevent: a dialog opens over a list, the user
    // clicks the dialog's empty background, and the list behind it selects a
    // row. Nothing the dialog draws can fix that, because by the time the row
    // is asked the decision has already been made.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 7 });

    const frame: Rect = .{ .x = 10, .y = 5, .w = 20, .h = 8 };
    h.beginLayer(frame);
    h.add(.{ .x = 12, .y = 10, .w = 6, .h = 1 }, .button);
    h.endLayer();

    // The modal's own control.
    try testing.expectEqual(TestAction.button, h.at(13, 10).?);
    // Its blank interior: swallowed, not passed down.
    try testing.expectEqual(@as(?TestAction, null), h.at(25, 6));
    // Outside it, the list is still live.
    try testing.expectEqual(TestAction{ .row = 7 }, h.at(2, 2).?);
}

test "a modal can claim the whole screen to catch a click outside itself" {
    // How "click anywhere else to dismiss" is built: the layer swallows
    // everything, and the outside is registered rather than left to fall
    // through.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 7 });

    h.beginLayer(.{ .x = 0, .y = 0, .w = 40, .h = 20 });
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .dismiss);
    h.add(.{ .x = 12, .y = 10, .w = 6, .h = 1 }, .button);
    h.endLayer();

    try testing.expectEqual(TestAction.button, h.at(13, 10).?);
    try testing.expectEqual(TestAction.dismiss, h.at(2, 2).?);
}

test "a transparent overlay lets clicks through" {
    // A tooltip is drawn above everything and controls nothing. Swallowing
    // clicks under it would make the UI go dead wherever a hint happens to be.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 7 });

    h.beginLayer(null);
    h.add(.{ .x = 12, .y = 10, .w = 6, .h = 1 }, .button);
    h.endLayer();

    try testing.expectEqual(TestAction.button, h.at(13, 10).?);
    try testing.expectEqual(TestAction{ .row = 7 }, h.at(25, 6).?);
}

test "layers nest and unwind" {
    // A dropdown inside a modal: the innermost layer answers first, and
    // closing it hands the modal back its clicks rather than the base.
    var h: TestHits = .{};
    h.add(.{ .x = 0, .y = 0, .w = 40, .h = 20 }, .{ .row = 1 });

    h.beginLayer(.{ .x = 5, .y = 5, .w = 30, .h = 10 });
    h.add(.{ .x = 6, .y = 6, .w = 4, .h = 1 }, .button);

    h.beginLayer(.{ .x = 8, .y = 7, .w = 10, .h = 4 });
    h.add(.{ .x = 9, .y = 8, .w = 3, .h = 1 }, .dismiss);
    h.endLayer();

    h.endLayer();

    try testing.expectEqual(TestAction.dismiss, h.at(10, 8).?);
    // Inside the dropdown but not on its item: the dropdown keeps it.
    try testing.expectEqual(@as(?TestAction, null), h.at(16, 9));
    // Inside the modal, outside the dropdown: the modal's control still works.
    try testing.expectEqual(TestAction.button, h.at(7, 6).?);
    // Outside everything.
    try testing.expectEqual(TestAction{ .row = 1 }, h.at(1, 1).?);
}

test "clearing forgets the layers as well as the entries" {
    // Layers are opened while drawing, and a frame that returns early leaves
    // the stack deep. Carrying that into the next frame would make the base
    // layer start life underneath a modal that no longer exists.
    var h: TestHits = .{};
    h.beginLayer(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    h.add(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .button);

    h.clear();
    h.add(.{ .x = 0, .y = 0, .w = 4, .h = 1 }, .{ .row = 0 });
    try testing.expectEqual(TestAction{ .row = 0 }, h.at(1, 0).?);
    try testing.expectEqual(@as(?TestAction, null), h.at(6, 6));
}

const TestId = union(enum) { field: u16, button: u16, dialog: u16 };
const TestFocus = Focus(TestId, 32);

/// One frame's worth of registrations, so the tests read like drawing code.
fn drawFrame(f: *TestFocus, base: []const TestId, overlay: ?[]const TestId) void {
    f.beginFrame();
    for (base) |id| f.register(id);
    if (overlay) |ids| {
        f.beginLayer();
        for (ids) |id| f.register(id);
        f.endLayer();
    }
    f.endFrame();
}

test "focus lands somewhere on the first frame" {
    // A UI that starts with nothing focused answers no keys until the user
    // finds something to click, which reads as broken rather than as empty.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "tab cycles and wraps within the layer" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);

    f.next();
    try testing.expectEqual(TestId{ .button = 1 }, f.focused().?);
    f.next();
    f.next();
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
    f.prev();
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
}

test "an overlay takes the keyboard the frame it appears" {
    // Nobody writes this. The dialog registered in a layer, so it has focus -
    // which is the whole reason the rule is worth having.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);

    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, &.{ .{ .dialog = 0 }, .{ .dialog = 1 } });
    try testing.expectEqual(TestId{ .dialog = 0 }, f.focused().?);
}

test "tab cannot escape an overlay" {
    // Tabbing out of a modal is how a user ends up typing into something they
    // cannot see, and then reports that the dialog "does nothing".
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, &.{ .{ .dialog = 0 }, .{ .dialog = 1 } });

    for (0..6) |_| {
        f.next();
        try testing.expect(f.focused().? == .dialog);
    }
}

test "closing an overlay hands the keyboard back where it was" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    f.next();
    f.next();
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);

    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, &.{.{ .dialog = 0 }});
    try testing.expectEqual(TestId{ .dialog = 0 }, f.focused().?);

    // Dismissed. Not back to the top of the list - back to where the user was.
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
}

test "focus on a control that stops being drawn is repaired" {
    // A list scrolls, a row is filtered away, a tab changes. The focused id
    // survives the frame and the control does not, and the symptom is a
    // keyboard that stops answering with nothing drawn wrong.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 7 } }, null);
    f.set(.{ .button = 7 });
    try testing.expectEqual(TestId{ .button = 7 }, f.focused().?);

    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 8 } }, null);
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "a frame with nothing focusable leaves nothing focused" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{.{ .field = 0 }}, null);
    drawFrame(&f, &.{}, null);
    try testing.expectEqual(@as(?TestId, null), f.focused());
    // And moving focus over an empty registry does nothing rather than trap.
    f.next();
    f.prev();
    try testing.expectEqual(@as(?TestId, null), f.focused());
}

test "setting focus to something undrawn is ignored" {
    // The id comes from a click, an action, a restored session. Accepting one
    // that was never drawn strands the keyboard on a control that cannot be
    // seen or reached.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    f.set(.{ .button = 99 });
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "focus buried under an overlay is remembered, not lost" {
    // The distinction from the repair case: the control is still drawn, just
    // underneath. Forgetting it here is what makes a dialog dismiss feel like
    // it reset the screen.
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 5 } }, null);
    f.set(.{ .button = 5 });

    for (0..3) |_| {
        drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 5 } }, &.{.{ .dialog = 0 }});
    }
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 5 } }, null);
    try testing.expectEqual(TestId{ .button = 5 }, f.focused().?);
}

test "has answers for the focus ring" {
    var f: TestFocus = .{};
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    try testing.expect(f.has(.{ .field = 0 }));
    try testing.expect(!f.has(.{ .button = 1 }));
}

test "focus starts where the client says, not where drawing happened to begin" {
    // The damage this prevents is specific: a sidebar draws its search box
    // first, so the application opens with the keyboard inside a text field,
    // every single letter shortcut is dead, and nothing on screen says why.
    var f: TestFocus = .{ .initial = .{ .button = 1 } };
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    try testing.expectEqual(TestId{ .button = 1 }, f.focused().?);

    // Only a starting point. Once the user moves, it stops applying.
    f.next();
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 }, .{ .button = 2 } }, null);
    try testing.expectEqual(TestId{ .button = 2 }, f.focused().?);
}

test "a starting point that is not drawn falls back rather than stranding" {
    var f: TestFocus = .{ .initial = .{ .button = 99 } };
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, null);
    try testing.expectEqual(TestId{ .field = 0 }, f.focused().?);
}

test "an overlay still wins over the starting point" {
    // The rule that focus lives in the top layer is not negotiable by a
    // preference expressed for the base layer.
    var f: TestFocus = .{ .initial = .{ .button = 1 } };
    drawFrame(&f, &.{ .{ .field = 0 }, .{ .button = 1 } }, &.{.{ .dialog = 0 }});
    try testing.expectEqual(TestId{ .dialog = 0 }, f.focused().?);
}
