const std = @import("std");
const Io = std.Io;
const ui = @import("telar-core").ui;
const diff = @import("diff.zig");
const pointer = @import("pointer.zig");

// The half of a TUI that speaks the terminal's language: the diff, the escape
// sequences it turns into, and the parser for what comes back.
//
// Portable, all of it. Bytes in and bytes out - not a syscall in the file, and
// no idea which operating system is on the other end. Opening the terminal,
// putting it into raw mode and noticing it resized are the parts that actually
// differ, and they live in `platform.zig`.
//
// `ui.zig` in turn knows none of *this*. The split is not tidiness: it is what
// lets layout and drawing be tested with no pty in sight, the same reason
// herdr keeps `AppState` free of PTYs and `render()` free of mutation.

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const DamageRow = diff.DamageRow;

/// Two buffers and the difference between them.
///
/// `back` is what was just drawn; `front` is what the terminal is currently
/// showing. Only the cells that differ are sent. This is the whole reason a
/// terminal UI can feel immediate: a blinking cursor costs one cell, not a
/// screen, and an agent printing a megabyte still costs only the cells that
/// ended up visible.
pub const Screen = struct {
    front: ui.Buffer,
    back: ui.Buffer,
    damage_rows: []DamageRow,
    full_damage: bool = true,
    gpa: std.mem.Allocator,

    /// Where to leave the terminal's own cursor, and whether to show it.
    ///
    /// A full screen UI normally hides it and draws its own, because a hardware
    /// cursor parked wherever the last write landed is a distraction. A text
    /// field is the exception: the real cursor is what screen readers follow
    /// and what a terminal's own input method composes against, so a field that
    /// paints a block instead is invisible to both. It also blinks for free.
    cursor: ?Position = null,
    /// Desired host mouse pointer and the last shape confirmed by a successful
    /// flush. `null` forces recovery to re-emit the desired shape.
    mouse_pointer: pointer.Shape = .default,
    presented_mouse_pointer: ?pointer.Shape = null,
    graphics: ?GraphicsEffect = null,

    pub const GraphicsEffect = struct {
        context: *anyopaque,
        write: *const fn (*anyopaque, *Io.Writer) Io.Writer.Error!usize,
    };

    pub const Position = struct { x: u16, y: u16 };

    pub const Stats = struct {
        /// Cells actually written. The number to watch: if idle frames are not
        /// near zero, something is being redrawn that did not change.
        cells: usize = 0,
        /// Candidate cells compared. This should follow the damage size, not
        /// the terminal size, for incremental frames.
        scanned: usize = 0,
        bytes: usize = 0,
        graphics_bytes: usize = 0,
    };

    pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !Screen {
        var front = try ui.Buffer.init(gpa, w, h);
        errdefer front.deinit();
        var back = try ui.Buffer.init(gpa, w, h);
        errdefer back.deinit();
        const damage_rows = try gpa.alloc(DamageRow, h);
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
    pub fn buffer(s: *Screen) *ui.Buffer {
        s.full_damage = true;
        return &s.back;
    }

    pub fn sizeMatches(s: *const Screen, w: u16, h: u16) bool {
        return s.back.w == w and s.back.h == h;
    }

    /// Returns a writable linear patch and records the rows it intersects.
    /// The returned slice is valid until resize, like the backing buffer.
    pub fn patchCells(s: *Screen, start: u32, count: u32) ![]ui.Cell {
        const first: usize = start;
        const len: usize = count;
        const end = std.math.add(usize, first, len) catch return error.PatchOutOfBounds;
        if (len == 0 or end > s.back.cells.len) {
            return error.PatchOutOfBounds;
        }

        diff.markRows(s.damage_rows, s.back.w, .{ .start = first, .count = len });
        return s.back.cells[first..end];
    }

    pub fn resize(s: *Screen, w: u16, h: u16) !void {
        const damage_rows = try s.gpa.alloc(DamageRow, h);
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
    pub fn flush(s: *Screen, w: *Io.Writer) !Stats {
        // The diff commits cells into `front` as it emits them. If the writer
        // fails partway, `front` claims cells the terminal never received, so
        // the only honest recovery is to forget the terminal's contents and
        // repaint everything on the next flush.
        errdefer s.invalidate();
        var stats: Stats = .{};
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

        var last_style: ?ui.Style = null;
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
                    try writeStyle(w, next.style);
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
};

/// The run sink most composition layers want: copy the run straight into the
/// screen's back buffer through `patchCells`, so damage stays exact.
pub const PatchSink = struct {
    screen: *Screen,
    source_row: []const ui.Cell,
    /// Linear cell index of `source_row[0]` in the screen buffer.
    base: usize,

    pub fn copyRun(sink: *PatchSink, run_start: u16, count: u16) !void {
        const destination = try sink.screen.patchCells(@intCast(sink.base + run_start), count);
        @memcpy(destination, sink.source_row[run_start..][0..count]);
    }
};

fn writeStyle(w: *Io.Writer, style: ui.Style) !void {
    // Reset first: turning attributes off individually needs one code per
    // attribute and a memory of which were on. Resetting costs four bytes.
    try w.writeAll("\x1b[0");
    const f = style.flags;
    if (f.bold) {
        try w.writeAll(";1");
    }
    if (f.faint) {
        try w.writeAll(";2");
    }
    if (f.italic) {
        try w.writeAll(";3");
    }
    if (f.blink) {
        try w.writeAll(";5");
    }
    if (f.inverse) {
        try w.writeAll(";7");
    }
    if (f.invisible) {
        try w.writeAll(";8");
    }
    if (f.strikethrough) {
        try w.writeAll(";9");
    }
    if (f.overline) {
        try w.writeAll(";53");
    }
    // SGR 4:n rather than plain 4, so a curly underline stays curly. Terminals
    // that do not know the sub-parameter form fall back to a plain underline,
    // which is the right degradation.
    if (f.underline != .none) {
        try w.print(";4:{d}", .{@intFromEnum(f.underline)});
    }
    switch (style.fg) {
        .default => {},
        .indexed => |i| try w.print(";38;5;{d}", .{i}),
        .rgb => |c| try w.print(";38;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
    }
    switch (style.bg) {
        .default => {},
        .indexed => |i| try w.print(";48;5;{d}", .{i}),
        .rgb => |c| try w.print(";48;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
    }
    // Only when there is an underline to colour. Emitting SGR 58 unconditionally
    // costs bytes on every run and confuses terminals that parse it loosely.
    if (f.underline != .none) {
        switch (style.underline_color) {
            .default => {},
            .indexed => |i| try w.print(";58;5;{d}", .{i}),
            .rgb => |c| try w.print(";58;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
        }
    }
    try w.writeAll("m");
}

// ---------------------------------------------------------------------------
// The clipboard
// ---------------------------------------------------------------------------

/// The largest payload we will try to send.
///
/// There is no standard limit, and terminals pick their own; a sequence past
/// whatever a given one accepts is silently ignored, which looks exactly like a
/// copy that did nothing. Refusing loudly at a known size is better than
/// succeeding on some machines.
pub const max_clipboard_bytes = 64 * 1024;

pub const ClipboardError = error{TooLarge};

/// Puts `payload` on the system clipboard with OSC 52.
///
/// The point of doing it this way rather than shelling out to `pbcopy` or
/// `xclip`: OSC 52 is *bytes on the same stream as everything else*, so it
/// works through SSH, through tmux, and inside a container, none of which have
/// access to the clipboard of the machine the human is sitting at.
///
/// Two things a caller should know. Some terminals ship with this disabled,
/// because a program that can write your clipboard is a program that can put a
/// command there - so a copy can legitimately do nothing and there is no reply
/// to check. And that is why the terminal's own Shift-drag selection has to
/// keep working: it is the fallback for exactly this case.
/// Writes one OSC 9 host notification. Callers pass pre-sanitized text with
/// no control bytes.
///
/// ```zig
/// try writeHostNotification(writer, "Agent done", "Claude in pane 2");
/// ```
pub fn writeHostNotification(w: *Io.Writer, title: []const u8, message: []const u8) Io.Writer.Error!void {
    try w.writeAll("\x1b]9;");
    try w.writeAll(title);
    if (message.len != 0) {
        try w.writeAll(": ");
        try w.writeAll(message);
    }
    try w.writeAll("\x07");
}

pub fn writeClipboard(w: *Io.Writer, payload: []const u8) (ClipboardError || Io.Writer.Error)!void {
    if (payload.len > max_clipboard_bytes) {
        return error.TooLarge;
    }

    // `c` is the selection name: the clipboard proper rather than the X11
    // primary selection, which is the one that pastes on middle click and is
    // not what a user means by "copy".
    try w.writeAll("\x1b]52;c;");

    const Encoder = std.base64.standard.Encoder;
    var chunk: [3 * 512]u8 = undefined;
    var encoded: [4 * 512]u8 = undefined;
    var at: usize = 0;
    while (at < payload.len) {
        // In multiples of three, so each chunk encodes independently: base64
        // pads at the end of its input, and padding in the middle of a stream
        // decodes to garbage.
        const take = @min(chunk.len, payload.len - at);
        @memcpy(chunk[0..take], payload[at..][0..take]);
        try w.writeAll(Encoder.encode(encoded[0..Encoder.calcSize(take)], chunk[0..take]));
        at += take;
    }

    // BEL rather than ST: both terminate an OSC, and BEL is the form every
    // terminal understands.
    try w.writeAll("\x07");
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    terminal_response: TerminalResponse,
    /// Bracketed paste boundaries.
    ///
    /// Between these, the characters that arrive were pasted rather than
    /// typed - and a newline among them is *text*, not the Enter key. Without
    /// the distinction, pasting three lines into a prompt runs three commands,
    /// which is both the classic annoyance and the reason a copied line from a
    /// web page can execute something.
    ///
    /// Delivered as markers with ordinary character events between them, not
    /// as one event carrying the payload. A slice would not survive the queue,
    /// and buffering an unbounded paste inside the parser would need an
    /// allocator on the keystroke path. The cost is that a large paste is many
    /// events; for the fields this drives, that is not a size anybody reaches.
    paste_start,
    paste_end,
    /// Bytes that arrived but do not yet form a complete sequence.
    incomplete,

    pub const Rgb8 = struct { r: u8, g: u8, b: u8 };

    pub const TerminalResponse = union(enum) {
        kitty_graphics: struct { image_id: u32, supported: bool },
        window_pixels: struct { width: u32, height: u32 },
        cell_pixels: struct { width: u32, height: u32 },
        mouse_pixels: struct { supported: bool },
        background_color: Rgb8,
        primary_device_attributes,
    };

    pub const Key = struct {
        code: Code,
        mods: Mods = .{},
        phase: Phase = .press,
        physical: ?Physical = null,
        kitty: ?KittyCodepoints = null,

        pub const Phase = enum(u2) {
            press = 1,
            repeat = 2,
            release = 3,
        };

        pub const Physical = struct {
            value: u32,

            /// Compares the stable identity carried by lifecycle reports.
            ///
            /// ```zig
            /// if (press.physical.?.eql(release.physical.?)) finishLease();
            /// ```
            pub fn eql(a: Physical, b: Physical) bool {
                return a.value == b.value;
            }
        };

        pub const KittyCodepoints = struct {
            primary: u32,
            shifted: ?u32 = null,
            base: ?u32 = null,
        };

        pub const Code = union(enum) {
            char: Char,
            up,
            down,
            left,
            right,
            home,
            end,
            delete,
            page_up,
            page_down,
            enter,
            escape,
            backspace,
            tab,
            /// Shift+Tab, which terminals send as CSI Z rather than as a
            /// modified tab. Nothing about the byte says "shift", so the
            /// parser has to.
            back_tab,
        };

        /// Held modifiers.
        ///
        /// Orthogonal rather than variants, because that is what they are: a
        /// `ctrl` case in the key union cannot express Ctrl+Shift+Left, and
        /// every text field needs Shift+Left the moment it grows a selection.
        pub const Mods = packed struct(u3) {
            shift: bool = false,
            alt: bool = false,
            ctrl: bool = false,
        };

        pub fn plain(code: Code) Key {
            return .{ .code = code };
        }

        /// Whether this is `Ctrl` plus a specific letter, case insensitive.
        pub fn isCtrl(k: Key, letter: u8) bool {
            if (!k.mods.ctrl) {
                return false;
            }
            return switch (k.code) {
                .char => |c| c.len == 1 and std.ascii.toLower(c.bytes[0]) == letter,
                else => false,
            };
        }
    };

    /// A printable key, stored inline rather than as a slice.
    ///
    /// Events cross a queue, and the bytes they were parsed from belong to a
    /// buffer the reader is about to compact. A slice into it is valid for
    /// exactly as long as nobody reads the next chunk - which is to say, until
    /// someone pastes. Four bytes is the longest UTF-8 encoding there is.
    pub const Char = struct {
        bytes: [4]u8 = @splat(0),
        len: u8 = 0,

        pub fn init(text: []const u8) Char {
            var c: Char = .{ .len = @intCast(@min(text.len, 4)) };
            @memcpy(c.bytes[0..c.len], text[0..c.len]);
            return c;
        }

        pub fn slice(c: *const Char) []const u8 {
            return c.bytes[0..c.len];
        }

        pub fn eql(c: *const Char, text: []const u8) bool {
            return std.mem.eql(u8, c.slice(), text);
        }
    };

    pub const Mouse = struct {
        x: u16,
        y: u16,
        raw_x: u32 = 0,
        raw_y: u32 = 0,
        kind: Kind,
        button: u8 = 0,

        pub const Kind = enum { press, release, drag, scroll_up, scroll_down, move };
    };
};

pub const Parsed = struct {
    event: Event,
    /// Bytes consumed. Zero means the input is a prefix of something longer and
    /// the caller should read more before trying again.
    len: usize,
};

/// Reads one event from the front of `input`.
///
/// Terminal input is a stream, not a sequence of messages: a mouse report can
/// arrive split across two reads, and an escape key is indistinguishable from
/// the start of an arrow key until the next byte does or does not come. This
/// reports `incomplete` with a length of zero and lets the caller keep the
/// bytes, which is the only honest thing to do.
/// Parses one OSC reply from the host. Only the OSC 11 background report is
/// surfaced; every other OSC is consumed silently once its terminator
/// arrives.
fn parseOscReply(input: []const u8) Parsed {
    var end: usize = 2;
    var terminator_len: usize = 0;
    while (end < input.len) : (end += 1) {
        if (input[end] == 0x07) {
            terminator_len = 1;
            break;
        }
        if (input[end] == 0x1b) {
            if (end + 1 >= input.len) {
                return .{ .event = .incomplete, .len = 0 };
            }
            if (input[end + 1] == '\\') {
                terminator_len = 2;
                break;
            }
            return .{ .event = .incomplete, .len = end };
        }
    } else return .{ .event = .incomplete, .len = 0 };

    const length = end + terminator_len;
    const body = input[2..end];
    if (std.mem.startsWith(u8, body, "11;")) {
        if (parseOscColor(body[3..])) |color| {
            return .{ .event = .{ .terminal_response = .{ .background_color = color } }, .len = length };
        }
    }

    return .{ .event = .incomplete, .len = length };
}

/// Accepts `rgb:RRRR/GGGG/BBBB` with 1..4 hex digits per channel, scaling to
/// eight bits from the leading digits.
fn parseOscColor(text: []const u8) ?Event.Rgb8 {
    if (!std.mem.startsWith(u8, text, "rgb:")) {
        return null;
    }
    var channels: [3]u8 = undefined;
    var iterator = std.mem.splitScalar(u8, text[4..], '/');
    for (&channels) |*channel| {
        const digits = iterator.next() orelse return null;
        if (digits.len == 0 or digits.len > 4) {
            return null;
        }
        var value: u16 = 0;
        for (digits[0..@min(digits.len, 2)]) |digit| {
            value = value * 16 + (std.fmt.charToDigit(digit, 16) catch return null);
        }
        channel.* = if (digits.len == 1) @intCast(value * 17) else @intCast(value);
    }
    if (iterator.next() != null) {
        return null;
    }
    return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
}

pub fn parse(input: []const u8) ?Parsed {
    if (input.len == 0) {
        return null;
    }

    if (input[0] != 0x1b) {
        return parseByte(input);
    }

    // A lone escape. Stream routers disambiguate it with a timeout; direct UI
    // callers that already own event framing can treat it as the key itself.
    if (input.len == 1) {
        return key(.escape, .{}, 1);
    }
    if (input[1] == '_') {
        return parseApc(input);
    }
    if (input[1] == ']') {
        return parseOscReply(input);
    }
    // SS3, which is what a terminal in application cursor mode sends for the
    // arrows and for Home and End. Ignoring it makes those keys dead in exactly
    // the terminals that use it.
    if (input[1] == 'O') {
        return parseSs3(input);
    }
    // Traditional terminals encode Alt+key as Escape followed by the key's
    // ordinary bytes. Once both bytes have arrived this is one modified key;
    // a stream reader still needs a timeout to distinguish a lone Escape.
    if (input[1] != '[') {
        return parseAlt(input);
    }
    if (input.len == 2) {
        return .{ .event = .incomplete, .len = 0 };
    }

    if (input[2] == '<') {
        return parseMouse(input);
    }

    // Unmodified arrows, and the two forms of Home and End that need no
    // parameters.
    switch (input[2]) {
        'A' => return physicalKey(.{ .code = .up }, 3),
        'B' => return physicalKey(.{ .code = .down }, 3),
        'C' => return physicalKey(.{ .code = .right }, 3),
        'D' => return physicalKey(.{ .code = .left }, 3),
        'H' => return physicalKey(.{ .code = .home }, 3),
        'F' => return physicalKey(.{ .code = .end }, 3),
        'Z' => return key(.back_tab, .{}, 3),
        else => {},
    }

    // A parameterised CSI: `ESC [ p1 ; p2 final`. Find the final byte first,
    // because everything else depends on having the whole sequence.
    var final: usize = 2;
    while (final < input.len and !(input[final] >= 0x40 and input[final] <= 0x7e)) {
        // ECMA-48: a new ESC aborts the sequence in progress. Consume only
        // the dead prefix, so the aborting sequence parses from its own
        // introducer instead of leaking its final bytes as typed characters.
        if (input[final] == 0x1b) {
            return .{ .event = .incomplete, .len = final };
        }
        final += 1;
    }
    if (final == input.len) {
        return .{ .event = .incomplete, .len = 0 };
    }

    var params: [3]u32 = .{ 0, 0, 0 };
    var count: usize = 0;
    var index: usize = 2;
    while (index < final) : (index += 1) {
        if (input[index] == ';') {
            count += 1;
            if (count == params.len) {
                break;
            }
            continue;
        }
        if (input[index] < '0' or input[index] > '9') {
            break;
        }
        params[count] = params[count] *| 10 +| (input[index] - '0');
    }
    const length = final + 1;

    if (input[final] == 'y' and
        std.mem.startsWith(u8, input[0..length], "\x1b[?1016;") and
        final >= 2 and input[final - 1] == '$')
    {
        const prefix_len = "\x1b[?1016;".len;
        const status = std.fmt.parseInt(u8, input[prefix_len .. final - 1], 10) catch 0;
        return .{ .event = .{ .terminal_response = .{ .mouse_pixels = .{
            .supported = status != 0,
        } } }, .len = length };
    }

    switch (input[final]) {
        // Kitty's disambiguation mode reports modified text keys as CSI-u,
        // keeping Ctrl+H distinct from Backspace and Ctrl+J from Enter.
        'u' => return parseKittyKey(input[2..final], length) orelse
            .{ .event = .incomplete, .len = length },
        // `ESC [ 1 ; modifier:event X` - a Kitty cursor-key lifecycle.
        'A' => return parseCursorKey(input[2..final], .up, length) orelse
            .{ .event = .incomplete, .len = length },
        'B' => return parseCursorKey(input[2..final], .down, length) orelse
            .{ .event = .incomplete, .len = length },
        'C' => return parseCursorKey(input[2..final], .right, length) orelse
            .{ .event = .incomplete, .len = length },
        'D' => return parseCursorKey(input[2..final], .left, length) orelse
            .{ .event = .incomplete, .len = length },
        'H' => return parseCursorKey(input[2..final], .home, length) orelse
            .{ .event = .incomplete, .len = length },
        'F' => return parseCursorKey(input[2..final], .end, length) orelse
            .{ .event = .incomplete, .len = length },
        // `ESC [ n ~` - the numbered keys, and the paste brackets.
        '~' => return parseTildeKey(input[2..final], length) orelse
            .{ .event = .incomplete, .len = length },
        't' => switch (params[0]) {
            4 => return .{ .event = .{ .terminal_response = .{ .window_pixels = .{
                .width = params[2],
                .height = params[1],
            } } }, .len = length },
            6 => return .{ .event = .{ .terminal_response = .{ .cell_pixels = .{
                .width = params[2],
                .height = params[1],
            } } }, .len = length },
            else => {},
        },
        'c' => return .{
            .event = .{ .terminal_response = .primary_device_attributes },
            .len = length,
        },
        else => {},
    }

    // Some other CSI. Skip it rather than choking: a terminal sends responses
    // nobody asked for, and dropping one unknown sequence beats desynchronising
    // the whole stream.
    return .{ .event = .incomplete, .len = length };
}

fn parseKittyKey(body: []const u8, length: usize) ?Parsed {
    var fields = std.mem.splitScalar(u8, body, ';');
    const codepoint_text = fields.next() orelse return null;
    const modifier_text = fields.next();
    if (fields.next() != null) {
        return null;
    }

    const codepoints = parseKittyCodepoints(codepoint_text) orelse return null;
    const modifier_event = parseKittyModifierEvent(modifier_text) orelse return null;
    const code = codepointCode(codepoints.primary) orelse return null;
    const mods = parseKeyModifiers(modifier_event.modifier) orelse return null;

    return .{
        .event = .{ .key = .{
            .code = code,
            .mods = mods,
            .phase = modifier_event.event,
            .physical = .{ .value = codepoints.base orelse codepoints.primary },
            .kitty = codepoints,
        } },
        .len = length,
    };
}

fn parseCursorKey(body: []const u8, code: Event.Key.Code, length: usize) ?Parsed {
    const parameters = parseFunctionKeyParameters(body) orelse return null;
    if (parameters.number != 1) {
        return null;
    }

    const mods = parseKeyModifiers(parameters.modifier_event.modifier) orelse return null;

    return physicalKey(.{
        .code = code,
        .mods = mods,
        .phase = parameters.modifier_event.event,
    }, length);
}

fn parseTildeKey(body: []const u8, length: usize) ?Parsed {
    if (std.mem.startsWith(u8, body, "27;")) {
        return parseModifyOtherKeys(body, length);
    }

    const parameters = parseFunctionKeyParameters(body) orelse return null;
    if (parameters.modifier_event.event == .press) {
        switch (parameters.number) {
            200 => return .{ .event = .paste_start, .len = length },
            201 => return .{ .event = .paste_end, .len = length },
            else => {},
        }
    }

    const code: Event.Key.Code = switch (parameters.number) {
        1, 7 => .home,
        3 => .delete,
        5 => .page_up,
        6 => .page_down,
        4, 8 => .end,
        else => return null,
    };
    const mods = parseKeyModifiers(parameters.modifier_event.modifier) orelse return null;

    return physicalKey(.{
        .code = code,
        .mods = mods,
        .phase = parameters.modifier_event.event,
    }, length);
}

const FunctionKeyParameters = struct {
    number: u32,
    modifier_event: KittyModifierEvent,
};

fn parseFunctionKeyParameters(body: []const u8) ?FunctionKeyParameters {
    var fields = std.mem.splitScalar(u8, body, ';');
    const number_text = fields.next() orelse return null;
    if (number_text.len == 0) {
        return null;
    }

    const number = std.fmt.parseUnsigned(u32, number_text, 10) catch return null;
    const modifier_event = parseKittyModifierEvent(fields.next()) orelse return null;
    if (fields.next() != null) {
        return null;
    }

    return .{ .number = number, .modifier_event = modifier_event };
}

const KittyModifierEvent = struct {
    modifier: u32,
    event: Event.Key.Phase,
};

fn parseKittyCodepoints(field: []const u8) ?Event.Key.KittyCodepoints {
    var values = std.mem.splitScalar(u8, field, ':');
    const primary = values.next() orelse return null;
    if (primary.len == 0) {
        return null;
    }

    const codepoint = parseUnicodeCodepoint(primary) orelse return null;
    const shifted_text = values.next() orelse return .{ .primary = codepoint };
    const base_text = values.next();
    if (values.next() != null) {
        return null;
    }
    if (shifted_text.len == 0 and base_text == null) {
        return null;
    }
    const shifted = if (shifted_text.len == 0)
        null
    else
        parseUnicodeCodepoint(shifted_text) orelse return null;
    const base = if (base_text) |value| parsed: {
        if (value.len == 0) {
            return null;
        }

        break :parsed parseUnicodeCodepoint(value) orelse return null;
    } else null;

    return .{ .primary = codepoint, .shifted = shifted, .base = base };
}

fn parseUnicodeCodepoint(text: []const u8) ?u32 {
    const value = std.fmt.parseUnsigned(u32, text, 10) catch return null;
    const scalar = std.math.cast(u21, value) orelse return null;
    var bytes: [4]u8 = undefined;
    _ = std.unicode.utf8Encode(scalar, &bytes) catch return null;

    return value;
}

fn parseKittyModifierEvent(field: ?[]const u8) ?KittyModifierEvent {
    const value = field orelse return .{ .modifier = 1, .event = .press };
    var parts = std.mem.splitScalar(u8, value, ':');
    const modifier_text = parts.next() orelse return null;
    if (modifier_text.len == 0) {
        return null;
    }

    const modifier = std.fmt.parseUnsigned(u32, modifier_text, 10) catch return null;
    const event_text = parts.next() orelse return .{ .modifier = modifier, .event = .press };
    if (event_text.len == 0 or parts.next() != null) {
        return null;
    }

    const event_value = std.fmt.parseUnsigned(u2, event_text, 10) catch return null;
    const event: Event.Key.Phase = switch (event_value) {
        1 => .press,
        2 => .repeat,
        3 => .release,
        else => return null,
    };
    return .{ .modifier = modifier, .event = event };
}

fn parseModifyOtherKeys(body: []const u8, length: usize) ?Parsed {
    var fields = std.mem.splitScalar(u8, body, ';');
    if (!std.mem.eql(u8, fields.next() orelse return null, "27")) {
        return null;
    }
    const modifier = std.fmt.parseUnsigned(u32, fields.next() orelse return null, 10) catch return null;
    const codepoint = std.fmt.parseUnsigned(u32, fields.next() orelse return null, 10) catch return null;
    if (fields.next() != null) {
        return null;
    }
    return codepointKey(codepoint, modifier, length);
}

fn codepointKey(codepoint: u32, modifier: u32, length: usize) ?Parsed {
    const mods = parseKeyModifiers(modifier) orelse return null;
    const code = codepointCode(codepoint) orelse return null;

    return key(code, mods, length);
}

fn codepointCode(codepoint: u32) ?Event.Key.Code {
    return switch (codepoint) {
        9 => .tab,
        13 => .enter,
        27 => .escape,
        127 => .backspace,
        else => character: {
            const scalar = std.math.cast(u21, codepoint) orelse return null;
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(scalar, &bytes) catch return null;
            break :character .{ .char = .init(bytes[0..len]) };
        },
    };
}

fn parseKeyModifiers(modifier: u32) ?Event.Key.Mods {
    if (modifier == 0) {
        return null;
    }

    const modifier_bits = modifier - 1;
    const unsupported_modifier_bits = modifier_bits & ~@as(u32, 0b1100_0111);
    if (unsupported_modifier_bits != 0) {
        return null;
    }

    return modsOf((modifier_bits & 0b111) + 1);
}

fn parseApc(input: []const u8) Parsed {
    var end: usize = 2;
    while (end + 1 < input.len) : (end += 1) {
        if (input[end] != 0x1b or input[end + 1] != '\\') {
            continue;
        }
        const length = end + 2;
        const content = input[2..end];
        if (content.len < 2 or content[0] != 'G') {
            return .{ .event = .incomplete, .len = length };
        }
        const separator = std.mem.indexOfScalar(u8, content, ';') orelse
            return .{ .event = .incomplete, .len = length };
        var image_id: u32 = 0;
        var fields = std.mem.splitScalar(u8, content[1..separator], ',');
        while (fields.next()) |field| {
            if (!std.mem.startsWith(u8, field, "i=")) {
                continue;
            }
            image_id = std.fmt.parseInt(u32, field[2..], 10) catch 0;
        }
        if (image_id == 0) {
            return .{ .event = .incomplete, .len = length };
        }
        const status = content[separator + 1 ..];
        return .{
            .event = .{ .terminal_response = .{ .kitty_graphics = .{
                .image_id = image_id,
                .supported = std.mem.eql(u8, status, "OK"),
            } } },
            .len = length,
        };
    }
    return .{ .event = .incomplete, .len = 0 };
}

fn parseByte(input: []const u8) ?Parsed {
    switch (input[0]) {
        // LF is Ctrl+J, also used by host mappings for multiline prompts.
        // Collapsing it into Enter would turn it into CR when re-encoded.
        '\r' => return key(.enter, .{}, 1),
        '\t' => return key(.tab, .{}, 1),
        // Both codes terminals send for the key marked Backspace.
        0x7f, 0x08 => return key(.backspace, .{}, 1),
        else => {},
    }

    // Control characters: Ctrl+A is 1, and so on up to Ctrl+Z. Reported as the
    // letter with a modifier rather than as its own kind of key, so a handler
    // that wants Ctrl+C and one that wants "c" read the same way.
    if (input[0] == 0) {
        return key(.{ .char = .init(" ") }, .{ .ctrl = true }, 1);
    }
    if (input[0] >= 1 and input[0] <= 26) {
        return key(.{ .char = .init(&.{input[0] + 'a' - 1}) }, .{ .ctrl = true }, 1);
    }
    if (input[0] >= 0x1c and input[0] <= 0x1f) {
        const controls = "\\]^_";
        return key(.{ .char = .init(controls[input[0] - 0x1c ..][0..1]) }, .{ .ctrl = true }, 1);
    }

    const length = std.unicode.utf8ByteSequenceLength(input[0]) catch 1;
    if (input.len < length) {
        return .{ .event = .incomplete, .len = 0 };
    }
    return key(.{ .char = .init(input[0..length]) }, .{}, length);
}

fn parseAlt(input: []const u8) Parsed {
    if (input[1] == 0x1b) {
        // ESC ESC: legacy terminals prefix a whole CSI or SS3 sequence with
        // ESC for a modified key, so Alt+Up arrives as `ESC ESC [ A`. Only
        // the third byte disambiguates that from Alt+Escape.
        if (input.len == 2) {
            return .{ .event = .incomplete, .len = 0 };
        }
        if (input[2] == '[' or input[2] == 'O') {
            const parsed = parse(input[1..]) orelse unreachable;
            if (parsed.len == 0) {
                return parsed;
            }
            return switch (parsed.event) {
                .key => |pressed| altKey(pressed, parsed.len + 1),
                else => .{ .event = .incomplete, .len = parsed.len + 1 },
            };
        }
        return key(.escape, .{ .alt = true }, 2);
    }
    const parsed = parseByte(input[1..]) orelse unreachable;
    if (parsed.len == 0) {
        return parsed;
    }
    return switch (parsed.event) {
        .key => |pressed| altKey(pressed, parsed.len + 1),
        else => .{ .event = .incomplete, .len = parsed.len + 1 },
    };
}

/// `ESC O X`, application cursor mode.
fn parseSs3(input: []const u8) ?Parsed {
    if (input.len < 3) {
        return .{ .event = .incomplete, .len = 0 };
    }
    return switch (input[2]) {
        'A' => physicalKey(.{ .code = .up }, 3),
        'B' => physicalKey(.{ .code = .down }, 3),
        'C' => physicalKey(.{ .code = .right }, 3),
        'D' => physicalKey(.{ .code = .left }, 3),
        'H' => physicalKey(.{ .code = .home }, 3),
        'F' => physicalKey(.{ .code = .end }, 3),
        else => .{ .event = .incomplete, .len = 3 },
    };
}

fn key(code: Event.Key.Code, mods: Event.Key.Mods, length: usize) Parsed {
    return .{ .event = .{ .key = .{ .code = code, .mods = mods } }, .len = length };
}

fn physicalKey(pressed: Event.Key, length: usize) Parsed {
    var leased = pressed;
    leased.physical = physicalIdentity(pressed.code);

    return .{
        .event = .{ .key = leased },
        .len = length,
    };
}

fn altKey(pressed: Event.Key, length: usize) Parsed {
    var modified = pressed;
    modified.mods.alt = true;

    return .{ .event = .{ .key = modified }, .len = length };
}

fn physicalIdentity(code: Event.Key.Code) Event.Key.Physical {
    return switch (code) {
        .char => |char| .{ .value = std.unicode.utf8Decode(char.slice()) catch 0 },
        .tab, .back_tab => .{ .value = @as(u32, 0x110000) + @intFromEnum(std.meta.Tag(Event.Key.Code).tab) },
        else => .{ .value = @as(u32, 0x110000) + @intFromEnum(std.meta.activeTag(code)) },
    };
}

/// The modifier parameter terminals send: one plus a bit per held modifier.
///
/// Zero means the parameter was absent, which is not the same as "no
/// modifiers" arithmetically - subtracting one from it would set every bit.
fn modsOf(param: u32) Event.Key.Mods {
    if (param == 0) {
        return .{};
    }
    const bits = param - 1;
    return .{
        .shift = bits & 1 != 0,
        .alt = bits & 2 != 0,
        .ctrl = bits & 4 != 0,
    };
}

/// Bytes in, events out, losing none.
///
/// A terminal hands over arbitrary fragments: half an escape sequence, three
/// events in one read, a multi byte character split across two. The obvious
/// buffer for that has a bug which only shows up under load, and it is the one
/// this type exists to make impossible:
///
///     const take = @min(pending.len - len, n);   // <- silently drops the rest
///
/// When the buffer still holds unparsed bytes and a read arrives that does not
/// fit in what is left, the excess vanishes. Nothing reports it. The symptom is
/// a keystroke that does nothing, and only while something else is producing
/// input - a mouse being moved, an autorepeating key - so it reads as the
/// terminal being flaky rather than as a program losing bytes.
///
/// Here `push` says how much it took and the caller feeds the rest after
/// draining, so no byte is ever passed over.
pub fn Input(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pending: [capacity]u8 = undefined,
        len: usize = 0,
        /// Bytes discarded to recover from an unparseable buffer. Not expected
        /// to move; worth a counter because "input is being dropped" is a fact
        /// nobody should have to infer from behaviour.
        dropped: usize = 0,

        /// Absorbs what fits, returning how many bytes it took.
        ///
        /// Zero means the buffer is full and the caller has to drain it with
        /// `next` before offering more. It never means the bytes are gone.
        pub fn push(in: *Self, chunk: []const u8) usize {
            const take = @min(capacity - in.len, chunk.len);
            @memcpy(in.pending[in.len..][0..take], chunk[0..take]);
            in.len += take;
            return take;
        }

        /// The next complete event, or null if more bytes are needed.
        pub fn next(in: *Self) ?Event {
            while (in.len > 0) {
                const parsed = parse(in.pending[0..in.len]) orelse return null;
                if (parsed.len == 0) {
                    // Needs more bytes - unless there is no more room for them,
                    // in which case the buffer holds something that will never
                    // parse and waiting is a deadlock. Dropping the oldest byte
                    // is the only move that guarantees progress.
                    if (in.len < capacity) {
                        return null;
                    }
                    in.discard(1);
                    in.dropped += 1;
                    continue;
                }
                in.discard(parsed.len);
                if (parsed.event == .incomplete) {
                    continue;
                }
                return parsed.event;
            }
            return null;
        }

        fn discard(in: *Self, count: usize) void {
            std.mem.copyForwards(u8, in.pending[0 .. in.len - count], in.pending[count..in.len]);
            in.len -= count;
        }
    };
}

/// SGR mouse reporting, `ESC [ < button ; column ; row M|m`.
///
/// Worth preferring over the older encoding because coordinates are decimal
/// rather than single bytes, so it keeps working past column 223 - which any
/// full screen terminal passes.
fn parseMouse(input: []const u8) ?Parsed {
    var index: usize = 3;
    var fields: [3]u32 = .{ 0, 0, 0 };
    var field: usize = 0;

    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= '0' and byte <= '9') {
            fields[field] = fields[field] *| 10 +| (byte - '0');
            continue;
        }
        if (byte == ';') {
            field += 1;
            if (field >= fields.len) {
                return .{ .event = .incomplete, .len = index + 1 };
            }
            continue;
        }
        // A new ESC aborts the report; keep it for the next parse.
        if (byte == 0x1b) {
            return .{ .event = .incomplete, .len = index };
        }
        if (byte != 'M' and byte != 'm') {
            return .{ .event = .incomplete, .len = index + 1 };
        }

        const button = fields[0];
        // Terminals count from one; everything above this counts from zero.
        const x = fields[1] -| 1;
        const y = fields[2] -| 1;

        const kind: Event.Mouse.Kind = if (button & 64 != 0)
            (if (button & 1 == 0) .scroll_up else .scroll_down)
        else if (button & 32 != 0)
            (if (button & 3 == 3) .move else .drag)
        else if (byte == 'm')
            .release
        else
            .press;

        return .{ .event = .{ .mouse = .{
            .x = std.math.cast(u16, x) orelse std.math.maxInt(u16),
            .y = std.math.cast(u16, y) orelse std.math.maxInt(u16),
            .raw_x = x,
            .raw_y = y,
            .kind = kind,
            .button = @truncate(button),
        } }, .len = index + 1 };
    }
    return .{ .event = .incomplete, .len = 0 };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const KeyCode = Event.Key.Code;

fn expectMouse(input: []const u8, x: u16, y: u16, kind: Event.Mouse.Kind) !void {
    const parsed = parse(input) orelse return error.NoEvent;
    try testing.expectEqual(input.len, parsed.len);
    try testing.expectEqual(x, parsed.event.mouse.x);
    try testing.expectEqual(y, parsed.event.mouse.y);
    try testing.expectEqual(kind, parsed.event.mouse.kind);
}

test "mouse reports are parsed and converted to zero based coordinates" {
    // Terminals count from one. Getting this wrong puts every click one cell
    // down and to the right, which looks like a layout bug for a long time.
    try expectMouse("\x1b[<0;1;1M", 0, 0, .press);
    try expectMouse("\x1b[<0;10;5M", 9, 4, .press);
    try expectMouse("\x1b[<0;10;5m", 9, 4, .release);
    try expectMouse("\x1b[<32;10;5M", 9, 4, .drag);
    try expectMouse("\x1b[<35;10;5M", 9, 4, .move);
    try expectMouse("\x1b[<64;10;5M", 9, 4, .scroll_up);
    try expectMouse("\x1b[<65;10;5M", 9, 4, .scroll_down);
}

test "Kitty graphics and pixel capability replies are consumed" {
    const kitty_reply = "\x1b_Gi=31;OK\x1b\\";
    // A single ESC is intentionally a complete key at this parser layer; the
    // stream router holds it until its ambiguity timeout. Once the APC
    // introducer is present, every proper prefix must remain incomplete.
    for (2..kitty_reply.len) |cut| {
        const parsed = parse(kitty_reply[0..cut]).?;
        try std.testing.expectEqual(@as(usize, 0), parsed.len);
    }
    const response = parse(kitty_reply).?.event.terminal_response.kitty_graphics;
    try std.testing.expectEqual(@as(u32, 31), response.image_id);
    try std.testing.expect(response.supported);

    const window = parse("\x1b[4;1080;1920t").?.event.terminal_response.window_pixels;
    try std.testing.expectEqual(@as(u32, 1920), window.width);
    try std.testing.expectEqual(@as(u32, 1080), window.height);
    const cell = parse("\x1b[6;20;10t").?.event.terminal_response.cell_pixels;
    try std.testing.expectEqual(@as(u32, 10), cell.width);
    try std.testing.expectEqual(@as(u32, 20), cell.height);
    const mouse_pixels = parse("\x1b[?1016;2$y").?.event.terminal_response.mouse_pixels;
    try std.testing.expect(mouse_pixels.supported);
    const no_mouse_pixels = parse("\x1b[?1016;0$y").?.event.terminal_response.mouse_pixels;
    try std.testing.expect(!no_mouse_pixels.supported);
}

test "coordinates past 223 survive, which the older encoding cannot" {
    try expectMouse("\x1b[<0;300;120M", 299, 119, .press);
    const pixels = parse("\x1b[<0;70000;80000M").?.event.mouse;
    try std.testing.expectEqual(@as(u32, 69999), pixels.raw_x);
    try std.testing.expectEqual(@as(u32, 79999), pixels.raw_y);
}

test "a split escape sequence is reported as incomplete, not misread" {
    // This is the failure that makes a TUI feel haunted: half a mouse report
    // arrives, gets parsed as an escape key plus garbage, and the application
    // reacts to a keystroke nobody made.
    const full = "\x1b[<0;10;5M";
    var cut: usize = 2;
    while (cut < full.len) : (cut += 1) {
        const parsed = parse(full[0..cut]) orelse return error.NoEvent;
        try testing.expectEqual(Event.incomplete, parsed.event);
        try testing.expectEqual(@as(usize, 0), parsed.len);
    }
    const parsed = parse(full).?;
    try testing.expectEqual(full.len, parsed.len);
}

test "keys" {
    try testing.expectEqual(KeyCode.up, parse("\x1b[A").?.event.key.code);
    try testing.expectEqual(KeyCode.down, parse("\x1b[B").?.event.key.code);
    try testing.expectEqual(KeyCode.enter, parse("\r").?.event.key.code);
    try testing.expectEqual(KeyCode.escape, parse("\x1b").?.event.key.code);
    try testing.expect(parse("a").?.event.key.code.char.eql("a"));

    // Ctrl is a modifier on the letter, not a kind of key. A handler that
    // wants Ctrl+C and one that wants "c" then read the same way.
    const ctrl_c = parse("\x03").?.event.key;
    try testing.expect(ctrl_c.mods.ctrl);
    try testing.expect(ctrl_c.isCtrl('c'));

    const alt_x = parse("\x1bx").?.event.key;
    try testing.expect(alt_x.mods.alt);
    try testing.expect(alt_x.code.char.eql("x"));

    const ctrl_alt_x = parse("\x1b\x18").?.event.key;
    try testing.expect(ctrl_alt_x.mods.alt);
    try testing.expect(ctrl_alt_x.mods.ctrl);
    try testing.expect(ctrl_alt_x.code.char.eql("x"));

    const ctrl_space = parse("\x00").?.event.key;
    try testing.expect(ctrl_space.mods.ctrl);
    try testing.expect(ctrl_space.code.char.eql(" "));
}

test "a key event survives the buffer it was parsed from" {
    // The reader compacts its buffer after every event it emits, and events
    // outlive that by sitting on a queue. A key holding a slice into the buffer
    // reads whatever landed there next, which shows up as the wrong character
    // appearing when text is pasted rather than typed.
    var buffer: [16]u8 = "hola".* ++ @as([12]u8, @splat(0));

    const parsed = parse(buffer[0..4]).?;
    const pressed = parsed.event.key;

    // Whatever the reader does to its buffer afterwards.
    @memset(&buffer, 0xaa);

    try testing.expect(pressed.code.char.eql("h"));
}

test "a multi byte character is not split across reads" {
    // 'ñ' is two bytes. Reporting the first alone would put a broken codepoint
    // into whatever the key feeds.
    const full = "ñ";
    try testing.expectEqual(@as(usize, 0), parse(full[0..1]).?.len);
    try testing.expect(parse(full).?.event.key.code.char.eql("ñ"));
}

test "an unknown escape sequence is consumed rather than desynchronising" {
    // Terminals volunteer replies nobody asked for. Skipping to the final byte
    // costs one dropped event; stopping at the first unknown byte costs every
    // event after it.
    const parsed = parse("\x1b[6;12R").?;
    try testing.expectEqual(@as(usize, 7), parsed.len);
    try testing.expectEqual(Event.incomplete, parsed.event);
}

test "the diff sends only what changed" {
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 40, 10);
    defer screen.deinit();

    var out: [16 * 1024]u8 = undefined;

    { // First frame: everything is new.
        var w = Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hello", .style = .{} });
        const stats = try screen.flush(&w);
        try testing.expectEqual(@as(usize, 40 * 10), stats.cells);
        try testing.expectEqual(@as(usize, 40 * 10), stats.scanned);
    }

    { // Redrawing the same thing costs nothing at all.
        var w = Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hello", .style = .{} });
        const stats = try screen.flush(&w);
        try testing.expectEqual(@as(usize, 0), stats.cells);
        try testing.expectEqual(@as(usize, 40 * 10), stats.scanned);
    }

    { // One changed word costs one word.
        var w = Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "world", .style = .{} });
        const stats = try screen.flush(&w);
        try testing.expectEqual(@as(usize, 4), stats.cells); // h,e,l,l -> w,o,r,l
    }
}

test "a resize forces a full repaint" {
    // Otherwise the diff compares against a screen the terminal no longer has,
    // and the result is the half drawn window everyone recognises.
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var w = Io.Writer.fixed(&out);
    screen.buffer().clear(.{});
    _ = try screen.flush(&w);

    try screen.resize(12, 4);
    var w2 = Io.Writer.fixed(&out);
    screen.buffer().clear(.{});
    const stats = try screen.flush(&w2);
    try testing.expectEqual(@as(usize, 12 * 4), stats.cells);
    try testing.expectEqual(@as(usize, 12 * 4), stats.scanned);
}

test "a protocol patch scans only its damaged cells" {
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    const patch = try screen.patchCells(12, 2);
    patch[0].bytes[0] = 'x';
    patch[1].bytes[0] = 'y';

    var writer = Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try testing.expectEqual(@as(usize, 2), stats.scanned);
    try testing.expectEqual(@as(usize, 2), stats.cells);
}

test "damage accumulates as one conservative range per row" {
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    const left = try screen.patchCells(1, 1);
    left[0].bytes[0] = 'x';
    const right = try screen.patchCells(8, 1);
    right[0].bytes[0] = 'y';

    var writer = Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try testing.expectEqual(@as(usize, 8), stats.scanned);
    try testing.expectEqual(@as(usize, 2), stats.cells);
}

test "a patch crossing rows keeps exact damage on both" {
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    const patch = try screen.patchCells(8, 4);
    for (patch, 0..) |*cell, index| cell.bytes[0] = @intCast('a' + index);

    var writer = Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try testing.expectEqual(@as(usize, 4), stats.scanned);
    try testing.expectEqual(@as(usize, 4), stats.cells);
}

test "a cursor-only frame scans no cells" {
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();

    var out: [8 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&out);
    _ = try screen.flush(&initial);

    screen.cursor = .{ .x = 3, .y = 1 };
    var writer = Io.Writer.fixed(&out);
    const stats = try screen.flush(&writer);
    try testing.expectEqual(@as(usize, 0), stats.scanned);
    try testing.expectEqual(@as(usize, 0), stats.cells);
}

test "tab and shift-tab are their own keys" {
    // Tab arrives as 0x09, which is also Ctrl+I. Reporting it as `ctrl` would
    // make every focus binding depend on that coincidence.
    const tab = parse("\t").?;
    try testing.expectEqual(KeyCode.tab, tab.event.key.code);
    try testing.expectEqual(@as(usize, 1), tab.len);

    // Shift+Tab is CSI Z. Before this it fell into the unknown-sequence path
    // and vanished, so focus could only ever move forwards.
    const back = parse("\x1b[Z").?;
    try testing.expectEqual(KeyCode.back_tab, back.event.key.code);
    try testing.expectEqual(@as(usize, 3), back.len);
}

test "a partial shift-tab asks for more bytes instead of guessing" {
    const partial = parse("\x1b[").?;
    try testing.expectEqual(Event.incomplete, partial.event);
    try testing.expectEqual(@as(usize, 0), partial.len);
}

test "modifiers arrive as modifiers, not as different keys" {
    // `ESC [ 1 ; mod D`. Shift+Left is what a selection is built out of, and
    // before this it fell into the unknown-sequence path and vanished.
    const shift_left = parse("\x1b[1;2D").?.event.key;
    try testing.expectEqual(KeyCode.left, shift_left.code);
    try testing.expect(shift_left.mods.shift);
    try testing.expect(!shift_left.mods.ctrl);

    const ctrl_right = parse("\x1b[1;5C").?.event.key;
    try testing.expectEqual(KeyCode.right, ctrl_right.code);
    try testing.expect(ctrl_right.mods.ctrl);
    try testing.expect(!ctrl_right.mods.shift);

    // Ctrl+Shift+Left: the combination a key union with a `ctrl` variant could
    // not express at all.
    const both = parse("\x1b[1;6D").?.event.key;
    try testing.expect(both.mods.ctrl and both.mods.shift);
}

test "Kitty keyboard mode disambiguates Ctrl keys from legacy controls" {
    const cases = [_]struct { sequence: []const u8, letter: []const u8 }{
        .{ .sequence = "\x1b[104;5u", .letter = "h" },
        .{ .sequence = "\x1b[106;5u", .letter = "j" },
        .{ .sequence = "\x1b[107;5u", .letter = "k" },
        .{ .sequence = "\x1b[108;5u", .letter = "l" },
    };
    for (cases) |case| {
        const parsed = parse(case.sequence).?;
        try testing.expectEqual(case.sequence.len, parsed.len);
        try testing.expect(parsed.event.key.mods.ctrl);
        try testing.expect(parsed.event.key.code.char.eql(case.letter));
    }

    try testing.expectEqual(KeyCode.escape, parse("\x1b[27u").?.event.key.code);
    try testing.expectEqual(KeyCode.enter, parse("\x1b[13u").?.event.key.code);
}

test "modified Enter is decoded from CSI-u and modifyOtherKeys" {
    const cases = [_]struct { sequence: []const u8, mods: Event.Key.Mods, phase: Event.Key.Phase, physical: bool }{
        .{ .sequence = "\x1b[13;2u", .mods = .{ .shift = true }, .phase = .press, .physical = true },
        .{ .sequence = "\x1b[13;2:1u", .mods = .{ .shift = true }, .phase = .press, .physical = true },
        .{ .sequence = "\x1b[13;2:2u", .mods = .{ .shift = true }, .phase = .repeat, .physical = true },
        .{ .sequence = "\x1b[13::13;2:1u", .mods = .{ .shift = true }, .phase = .press, .physical = true },
        .{ .sequence = "\x1b[27;2;13~", .mods = .{ .shift = true }, .phase = .press, .physical = false },
        .{ .sequence = "\x1b[13;6u", .mods = .{ .shift = true, .ctrl = true }, .phase = .press, .physical = true },
        .{ .sequence = "\x1b[27;6;13~", .mods = .{ .shift = true, .ctrl = true }, .phase = .press, .physical = false },
    };
    for (cases) |case| {
        const parsed = parse(case.sequence).?;
        const pressed = parsed.event.key;
        try testing.expectEqual(case.sequence.len, parsed.len);
        try testing.expectEqual(KeyCode.enter, pressed.code);
        try testing.expectEqual(case.mods, pressed.mods);
        try testing.expectEqual(case.phase, pressed.phase);
        if (case.physical) {
            try testing.expectEqual(@as(u32, 13), pressed.physical.?.value);
        } else {
            try testing.expect(pressed.physical == null);
        }
    }
}

test "Kitty alternate key codes preserve the primary key" {
    const cases = [_]struct { sequence: []const u8, expected: Event.Key }{
        .{
            .sequence = "\x1b[47:63:47;6:1u",
            .expected = .{
                .code = .{ .char = .init("/") },
                .mods = .{ .shift = true, .ctrl = true },
                .physical = .{ .value = 47 },
                .kitty = .{ .primary = 47, .shifted = 63, .base = 47 },
            },
        },
        .{
            .sequence = "\x1b[108::108;5:2u",
            .expected = .{
                .code = .{ .char = .init("l") },
                .mods = .{ .ctrl = true },
                .phase = .repeat,
                .physical = .{ .value = 108 },
                .kitty = .{ .primary = 108, .base = 108 },
            },
        },
    };
    for (cases) |case| {
        const parsed = parse(case.sequence).?;
        try testing.expectEqual(case.sequence.len, parsed.len);
        try testing.expectEqualDeep(Event{ .key = case.expected }, parsed.event);
    }
}

test "Kitty key releases remain semantic events without desynchronizing the stream" {
    const release = "\x1b[13::13;2:3u";
    const parsed = parse(release).?;
    try testing.expectEqual(release.len, parsed.len);
    try testing.expectEqual(KeyCode.enter, parsed.event.key.code);
    try testing.expectEqual(Event.Key.Phase.release, parsed.event.key.phase);
    try testing.expectEqual(@as(u32, 13), parsed.event.key.physical.?.value);

    var input: Input(32) = .{};
    try testing.expectEqual(release.len + 1, input.push(release ++ "x"));
    try testing.expectEqual(Event.Key.Phase.release, input.next().?.key.phase);
    try testing.expect(input.next().?.key.code.char.eql("x"));
    try testing.expect(input.next() == null);
}

test "Kitty key lifecycles parse at every boundary after the CSI introducer" {
    const cases = [_]struct { sequence: []const u8, code: KeyCode, phase: Event.Key.Phase, physical: u32 }{
        .{ .sequence = "\x1b[115::115;5:1u", .code = .{ .char = .init("s") }, .phase = .press, .physical = 115 },
        .{ .sequence = "\x1b[115::115;5:2u", .code = .{ .char = .init("s") }, .phase = .repeat, .physical = 115 },
        .{ .sequence = "\x1b[115::115;1:3u", .code = .{ .char = .init("s") }, .phase = .release, .physical = 115 },
        .{ .sequence = "\x1b[1;5:2A", .code = .up, .phase = .repeat, .physical = physicalIdentity(.up).value },
        .{ .sequence = "\x1b[1;1:3A", .code = .up, .phase = .release, .physical = physicalIdentity(.up).value },
        .{ .sequence = "\x1b[3;5:3~", .code = .delete, .phase = .release, .physical = physicalIdentity(.delete).value },
    };

    for (cases) |case| {
        for (2..case.sequence.len) |split| {
            var input: Input(64) = .{};
            _ = input.push(case.sequence[0..split]);
            try testing.expect(input.next() == null);
            _ = input.push(case.sequence[split..]);

            const pressed = input.next().?.key;
            try testing.expectEqualDeep(case.code, pressed.code);
            try testing.expectEqual(case.phase, pressed.phase);
            try testing.expectEqual(case.physical, pressed.physical.?.value);
            try testing.expect(input.next() == null);
        }
    }
}

test "malformed Kitty reports are consumed without producing keys" {
    for ([_][]const u8{
        "\x1b[;2u",
        "\x1b[13:;2u",
        "\x1b[13::;2u",
        "\x1b[13:14:15:16;2u",
        "\x1b[13;0:3u",
        "\x1b[13;2:u",
        "\x1b[13;2:0u",
        "\x1b[13;2:4u",
        "\x1b[13;2:1:1u",
        "\x1b[13:4294967296;2u",
        "\x1b[13:1114112;2u",
        "\x1b[13:55296;2u",
        "\x1b[13::1114112;2u",
        "\x1b[13::55296;2u",
        "\x1b[4294967296;2u",
        "\x1b[55296;2u",
    }) |sequence| {
        const parsed = parse(sequence).?;
        try testing.expectEqual(sequence.len, parsed.len);
        try testing.expectEqual(Event.incomplete, parsed.event);
    }
}

test "a bare line feed remains Ctrl+J instead of becoming Enter" {
    const parsed = parse("\n").?;
    try testing.expectEqual(@as(usize, 1), parsed.len);
    try testing.expect(parsed.event.key.isCtrl('j'));
    try testing.expectEqualDeep(Event{ .key = .plain(.enter) }, parse("\r").?.event);
}

test "malformed modifyOtherKeys reports are consumed without producing keys" {
    for ([_][]const u8{
        "\x1b[27;0;13~",
        "\x1b[27;;13~",
        "\x1b[27;2~",
        "\x1b[27;2;13;1~",
        "\x1b[27;2;13:1~",
        "\x1b[27;2;4294967296~",
        "\x1b[27;2;55296~",
        "\x1b[27;9;13~",
    }) |sequence| {
        const parsed = parse(sequence).?;
        try testing.expectEqual(sequence.len, parsed.len);
        try testing.expectEqual(Event.incomplete, parsed.event);
    }
}

test "an absent modifier parameter is no modifiers, not every modifier" {
    // The parameter is one *plus* the bits, so a missing one reads as zero and
    // subtracting blindly would set every bit - reporting a plain arrow as
    // Ctrl+Alt+Shift.
    const plain = parse("\x1b[D").?.event.key;
    try testing.expect(!plain.mods.shift and !plain.mods.ctrl and !plain.mods.alt);
}

test "home, end and delete in each of the forms terminals send" {
    for ([_][]const u8{ "\x1b[H", "\x1b[1~", "\x1b[7~", "\x1bOH" }) |sequence| {
        try testing.expectEqual(KeyCode.home, parse(sequence).?.event.key.code);
    }
    for ([_][]const u8{ "\x1b[F", "\x1b[4~", "\x1b[8~", "\x1bOF" }) |sequence| {
        try testing.expectEqual(KeyCode.end, parse(sequence).?.event.key.code);
    }
    try testing.expectEqual(KeyCode.delete, parse("\x1b[3~").?.event.key.code);
}

test "application cursor mode arrows are not dead keys" {
    // A terminal in this mode sends SS3 instead of CSI. Ignoring it makes the
    // arrows stop working in exactly the terminals that use it, which reads as
    // "your app is broken on my machine".
    try testing.expectEqual(KeyCode.up, parse("\x1bOA").?.event.key.code);
    try testing.expectEqual(KeyCode.left, parse("\x1bOD").?.event.key.code);
}

test "both bytes for backspace are backspace" {
    try testing.expectEqual(KeyCode.backspace, parse("\x7f").?.event.key.code);
    try testing.expectEqual(KeyCode.backspace, parse("\x08").?.event.key.code);
}

test "a paste is bracketed, so a newline inside it is text" {
    // The whole point. Without the brackets, pasting three lines into a prompt
    // runs three commands - the classic annoyance, and the reason a line copied
    // from a web page can execute something on arrival.
    const paste = "\x1b[200~one\ntwo\x1b[201~";
    var at: usize = 0;

    const start = parse(paste[at..]).?;
    try testing.expectEqual(Event.paste_start, start.event);
    at += start.len;

    var characters: usize = 0;
    var newlines: usize = 0;
    var enters: usize = 0;
    while (at < paste.len) {
        const parsed = parse(paste[at..]).?;
        at += parsed.len;
        switch (parsed.event) {
            .paste_end => break,
            .key => |k| {
                if (k.isCtrl('j')) {
                    newlines += 1;
                } else {
                    switch (k.code) {
                        .enter => enters += 1,
                        .char => characters += 1,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 0), enters);
    try testing.expectEqual(@as(usize, 1), newlines);
    try testing.expectEqual(@as(usize, 6), characters);
    try testing.expect(at == paste.len);
}

test "a partial paste marker asks for more bytes" {
    try testing.expectEqual(@as(usize, 0), parse("\x1b[200").?.len);
}

test "page keys use their numbered CSI forms" {
    try std.testing.expectEqual(Event.Key.Code.page_up, parse("\x1b[5~").?.event.key.code);
    try std.testing.expectEqual(Event.Key.Code.page_down, parse("\x1b[6~").?.event.key.code);
}

test "the real cursor is placed only when a field asks for it" {
    // A hardware cursor parked wherever the last write landed is a
    // distraction, so the default is hidden. A text field is the exception,
    // and it is the only thing a screen reader or an input method can follow.
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&out);

    _ = try screen.flush(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[?25l") != null);

    writer = .fixed(&out);
    screen.cursor = .{ .x = 4, .y = 1 };
    _ = try screen.flush(&writer);
    // One based, row first, and shown.
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2;5H") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[?25h") != null);
}

test "mouse pointer changes fold until a shape or recovery changes" {
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 3);
    defer screen.deinit();

    var out: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&out);

    _ = try screen.flush(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), pointer.sequence(.default)) != null);

    writer = .fixed(&out);
    screen.mouse_pointer = .pointer;
    _ = try screen.flush(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), pointer.sequence(.pointer)) != null);

    writer = .fixed(&out);
    _ = try screen.flush(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b]22;") == null);

    writer = .fixed(&out);
    screen.mouse_pointer = .horizontal_resize;
    _ = try screen.flush(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), pointer.sequence(.horizontal_resize)) != null);

    writer = .fixed(&out);
    screen.invalidate();
    _ = try screen.flush(&writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), pointer.sequence(.horizontal_resize)) != null);
}

test "no byte is lost when a read does not fit in what is left" {
    // The bug this type exists for. A buffer holding unparsed bytes gets a read
    // larger than its free space; the old code took what fit and discarded the
    // rest. Under a mouse burst that is a keystroke that does nothing, blamed
    // on the terminal.
    var in: Input(32) = .{};

    // Fill it with events that have not been drained yet.
    var burst: [64]u8 = undefined;
    @memset(&burst, 'a');

    var seen: usize = 0;
    var offset: usize = 0;
    while (offset < burst.len) {
        const took = in.push(burst[offset..]);
        offset += took;
        while (in.next()) |event| {
            try testing.expect(event.key.code.char.eql("a"));
            seen += 1;
        }
        // Progress is guaranteed: either bytes went in or events came out.
        if (took == 0 and in.len == 0) {
            return error.Stuck;
        }
    }
    try testing.expectEqual(burst.len, seen);
    try testing.expectEqual(@as(usize, 0), in.dropped);
}

test "a sequence split across reads survives the split" {
    var in: Input(64) = .{};
    _ = in.push("\x1b[1");
    try testing.expectEqual(@as(?Event, null), in.next());
    _ = in.push(";2D");

    const event = in.next().?;
    try testing.expectEqual(KeyCode.left, event.key.code);
    try testing.expect(event.key.mods.shift);
}

test "a buffer full of garbage recovers instead of deadlocking" {
    // An escape that never completes would otherwise sit there forever: `parse`
    // asks for more bytes, there is no room for more bytes, and the actor stops
    // reporting input at all.
    var in: Input(8) = .{};
    _ = in.push("\x1b[123456");
    try testing.expectEqual(@as(usize, 8), in.len);

    // Progress rather than a stall, and the loss is counted rather than silent.
    _ = in.next();
    try testing.expect(in.dropped > 0);

    // And it is usable again afterwards.
    while (in.next()) |_| {}
    _ = in.push("x");
    try testing.expect(in.next().?.key.code.char.eql("x"));
}

test "several events in one read all come out" {
    var in: Input(64) = .{};
    _ = in.push("ab\x1b[Ac");

    var codes: [4]KeyCode = undefined;
    var count: usize = 0;
    while (in.next()) |event| : (count += 1) codes[count] = event.key.code;

    try testing.expectEqual(@as(usize, 4), count);
    try testing.expect(codes[0].char.eql("a"));
    try testing.expect(codes[1].char.eql("b"));
    try testing.expectEqual(KeyCode.up, codes[2]);
    try testing.expect(codes[3].char.eql("c"));
}

test "an unknown sequence is consumed without being reported" {
    // Terminals volunteer replies nobody asked for. They must not surface as
    // events, and they must not stall the ones behind them.
    var in: Input(64) = .{};
    _ = in.push("\x1b[6;12Rz");
    const event = in.next().?;
    try testing.expect(event.key.code.char.eql("z"));
}

test "a sequence aborted by a new escape does not leak keystrokes" {
    // ECMA-48: an ESC aborts the control sequence in progress. Scanning past
    // it for a final byte swallowed the aborting sequence's introducer and
    // delivered its final bytes as typed characters.
    var in: Input(64) = .{};
    _ = in.push("\x1b[1\x1b[A");
    const event = in.next().?;
    try testing.expectEqual(KeyCode.up, event.key.code);
    try testing.expectEqual(@as(?Event, null), in.next());

    // The same abort inside a mouse report.
    var mouse_in: Input(64) = .{};
    _ = mouse_in.push("\x1b[<0;5\x1b[B");
    const after_mouse = mouse_in.next().?;
    try testing.expectEqual(KeyCode.down, after_mouse.key.code);
    try testing.expectEqual(@as(?Event, null), mouse_in.next());
}

test "a legacy alt-prefixed arrow is one modified key" {
    // Traditional terminals send Alt+Up as ESC ESC [ A. Reading the second
    // escape as Alt+Escape typed "[A" into whatever was focused.
    const parsed = parse("\x1b\x1b[A").?;
    try testing.expectEqual(KeyCode.up, parsed.event.key.code);
    try testing.expect(parsed.event.key.mods.alt);
    try testing.expectEqual(@as(usize, 4), parsed.len);

    // Two escapes alone stay ambiguous until the next byte arrives.
    try testing.expectEqual(@as(usize, 0), parse("\x1b\x1b").?.len);

    // Followed by anything that cannot start a sequence, it is Alt+Escape.
    const alt_escape = parse("\x1b\x1bx").?;
    try testing.expectEqual(KeyCode.escape, alt_escape.event.key.code);
    try testing.expect(alt_escape.event.key.mods.alt);
    try testing.expectEqual(@as(usize, 2), alt_escape.len);
}

test "a failed flush forgets nothing the terminal did not receive" {
    // Regression: the diff committed cells into `front` while emitting them,
    // so a writer error mid-flush left the screen claiming cells the terminal
    // never got, and the retry emitted nothing.
    const gpa = testing.allocator;
    var screen = try Screen.init(gpa, 10, 2);
    defer screen.deinit();
    var out: [8 * 1024]u8 = undefined;
    var initial = Io.Writer.fixed(&out);
    screen.buffer().clear(.{});
    _ = try screen.flush(&initial);

    screen.buffer().clear(.{});
    _ = screen.buffer().writeText(screen.buffer().area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "hola", .style = .{} });
    var tiny: [24]u8 = undefined;
    var failing = Io.Writer.fixed(&tiny);
    try testing.expectError(error.WriteFailed, screen.flush(&failing));

    var retry = Io.Writer.fixed(&out);
    const stats = try screen.flush(&retry);
    try testing.expect(stats.cells >= 4);
}

test "a copy is one osc 52 sequence with the text in base64" {
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    try writeClipboard(&w, "hola");

    // `c` is the clipboard proper, not the X11 primary selection - which pastes
    // on middle click and is not what anybody means by "copy".
    try testing.expectEqualStrings("\x1b]52;c;aG9sYQ==\x07", w.buffered());
}

test "a payload longer than one chunk still decodes" {
    // Encoded in pieces to bound the stack, and base64 pads at the end of its
    // input - so a chunk that is not a multiple of three would put padding in
    // the middle of the stream and everything after it would decode to garbage.
    var payload: [4000]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast('a' + i % 26);

    var out: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    try writeClipboard(&w, &payload);

    const written = w.buffered();
    const body = written["\x1b]52;c;".len .. written.len - 1];
    const Decoder = std.base64.standard.Decoder;
    var decoded: [4000]u8 = undefined;
    try Decoder.decode(&decoded, body);
    try testing.expectEqualSlices(u8, &payload, &decoded);
}

test "an oversized copy fails rather than silently doing nothing" {
    // Terminals ignore a sequence past whatever size they accept, with no
    // reply. Succeeding here would produce a copy that works on one machine and
    // not another, with nothing to look at.
    var out: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    var huge: [max_clipboard_bytes + 1]u8 = undefined;
    @memset(&huge, 'x');
    try testing.expectError(error.TooLarge, writeClipboard(&w, &huge));
}

test "an OSC 11 reply reports the host background and other OSCs are consumed" {
    const reply = "\x1b]11;rgb:1e1e/2222/2e2e\x1b\\";
    const parsed = parse(reply).?;
    try std.testing.expectEqual(reply.len, parsed.len);
    const color = parsed.event.terminal_response.background_color;
    try std.testing.expectEqual(@as(u8, 0x1e), color.r);
    try std.testing.expectEqual(@as(u8, 0x22), color.g);
    try std.testing.expectEqual(@as(u8, 0x2e), color.b);

    const bel = parse("\x1b]11;rgb:f/f/f\x07").?;
    try std.testing.expectEqual(@as(u8, 0xff), bel.event.terminal_response.background_color.r);

    const other = parse("\x1b]52;c;abc\x07").?;
    try std.testing.expect(other.event == .incomplete);
    try std.testing.expectEqual("\x1b]52;c;abc\x07".len, other.len);

    const partial = parse("\x1b]11;rgb:1e1e/22").?;
    try std.testing.expect(partial.event == .incomplete);
    try std.testing.expectEqual(@as(usize, 0), partial.len);
}
