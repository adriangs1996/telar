const std = @import("std");
const Io = std.Io;
const ui = @import("telar-core").ui;

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

    /// Where to leave the terminal's own cursor, and whether to show it.
    ///
    /// A full screen UI normally hides it and draws its own, because a hardware
    /// cursor parked wherever the last write landed is a distraction. A text
    /// field is the exception: the real cursor is what screen readers follow
    /// and what a terminal's own input method composes against, so a field that
    /// paints a block instead is invisible to both. It also blinks for free.
    cursor: ?Position = null,

    pub const Position = struct { x: u16, y: u16 };

    pub const Stats = struct {
        /// Cells actually written. The number to watch: if idle frames are not
        /// near zero, something is being redrawn that did not change.
        cells: usize = 0,
        bytes: usize = 0,
    };

    pub fn init(gpa: std.mem.Allocator, w: u16, h: u16) !Screen {
        var s: Screen = .{
            .front = try .init(gpa, w, h),
            .back = try .init(gpa, w, h),
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
    }

    pub fn deinit(s: *Screen) void {
        s.front.deinit();
        s.back.deinit();
    }

    /// The buffer to draw this frame into.
    pub fn buffer(s: *Screen) *ui.Buffer {
        return &s.back;
    }

    pub fn resize(s: *Screen, w: u16, h: u16) !void {
        try s.back.resize(w, h);
        try s.front.resize(w, h);
        // A resized terminal kept none of what was there.
        s.invalidate();
    }

    /// Sends the difference to `w`.
    pub fn flush(s: *Screen, w: *Io.Writer) !Stats {
        var stats: Stats = .{};
        const before = w.end;

        // Synchronised output: the terminal is told to hold the frame until it
        // is complete. Without it a large repaint tears, because the emulator
        // draws whatever has arrived so far. herdr wraps its own draw in this.
        try w.writeAll("\x1b[?2026h");

        var last_style: ?ui.Style = null;
        var cursor: ?struct { x: u16, y: u16 } = null;

        var y: u16 = 0;
        while (y < s.back.h) : (y += 1) {
            var x: u16 = 0;
            while (x < s.back.w) : (x += 1) {
                const index = @as(usize, y) * @as(usize, s.back.w) + @as(usize, x);
                const next = &s.back.cells[index];
                const current = &s.front.cells[index];

                // The trailing half of a wide glyph is not addressable: the
                // terminal advanced its own cursor over it when the first half
                // was drawn.
                if (next.width == 0) continue;
                if (next.eqlPublic(current)) continue;

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
        return stats;
    }
};

fn writeStyle(w: *Io.Writer, style: ui.Style) !void {
    // Reset first: turning attributes off individually needs one code per
    // attribute and a memory of which were on. Resetting costs four bytes.
    try w.writeAll("\x1b[0");
    const f = style.flags;
    if (f.bold) try w.writeAll(";1");
    if (f.faint) try w.writeAll(";2");
    if (f.italic) try w.writeAll(";3");
    if (f.blink) try w.writeAll(";5");
    if (f.inverse) try w.writeAll(";7");
    if (f.invisible) try w.writeAll(";8");
    if (f.strikethrough) try w.writeAll(";9");
    if (f.overline) try w.writeAll(";53");
    // SGR 4:n rather than plain 4, so a curly underline stays curly. Terminals
    // that do not know the sub-parameter form fall back to a plain underline,
    // which is the right degradation.
    if (f.underline != .none) try w.print(";4:{d}", .{@intFromEnum(f.underline)});
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
    if (f.underline != .none) switch (style.underline_color) {
        .default => {},
        .indexed => |i| try w.print(";58;5;{d}", .{i}),
        .rgb => |c| try w.print(";58;2;{d};{d};{d}", .{ c[0], c[1], c[2] }),
    };
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
pub fn writeClipboard(w: *Io.Writer, payload: []const u8) (ClipboardError || Io.Writer.Error)!void {
    if (payload.len > max_clipboard_bytes) return error.TooLarge;

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

    pub const Key = struct {
        code: Code,
        mods: Mods = .{},

        pub const Code = union(enum) {
            char: Char,
            up,
            down,
            left,
            right,
            home,
            end,
            delete,
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
            if (!k.mods.ctrl) return false;
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
        kind: Kind,

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
pub fn parse(input: []const u8) ?Parsed {
    if (input.len == 0) return null;

    if (input[0] != 0x1b) return parseByte(input);

    // A lone escape. Real terminals disambiguate this with a timeout; a spike
    // can treat "nothing followed yet" as the key itself.
    if (input.len == 1) return key(.escape, .{}, 1);
    // SS3, which is what a terminal in application cursor mode sends for the
    // arrows and for Home and End. Ignoring it makes those keys dead in exactly
    // the terminals that use it.
    if (input[1] == 'O') return parseSs3(input);
    if (input[1] != '[') return key(.escape, .{}, 1);
    if (input.len == 2) return .{ .event = .incomplete, .len = 0 };

    if (input[2] == '<') return parseMouse(input);

    // Unmodified arrows, and the two forms of Home and End that need no
    // parameters.
    switch (input[2]) {
        'A' => return key(.up, .{}, 3),
        'B' => return key(.down, .{}, 3),
        'C' => return key(.right, .{}, 3),
        'D' => return key(.left, .{}, 3),
        'H' => return key(.home, .{}, 3),
        'F' => return key(.end, .{}, 3),
        'Z' => return key(.back_tab, .{}, 3),
        else => {},
    }

    // A parameterised CSI: `ESC [ p1 ; p2 final`. Find the final byte first,
    // because everything else depends on having the whole sequence.
    var final: usize = 2;
    while (final < input.len and !(input[final] >= 0x40 and input[final] <= 0x7e)) final += 1;
    if (final == input.len) return .{ .event = .incomplete, .len = 0 };

    var params: [2]u16 = .{ 0, 0 };
    var count: usize = 0;
    var index: usize = 2;
    while (index < final) : (index += 1) {
        if (input[index] == ';') {
            count += 1;
            if (count == params.len) break;
            continue;
        }
        if (input[index] < '0' or input[index] > '9') break;
        params[count] = params[count] * 10 + (input[index] - '0');
    }
    const length = final + 1;

    switch (input[final]) {
        // `ESC [ 1 ; mod X` - a modified arrow, Home or End.
        'A' => return key(.up, modsOf(params[1]), length),
        'B' => return key(.down, modsOf(params[1]), length),
        'C' => return key(.right, modsOf(params[1]), length),
        'D' => return key(.left, modsOf(params[1]), length),
        'H' => return key(.home, modsOf(params[1]), length),
        'F' => return key(.end, modsOf(params[1]), length),
        // `ESC [ n ~` - the numbered keys, and the paste brackets.
        '~' => switch (params[0]) {
            1, 7 => return key(.home, modsOf(params[1]), length),
            3 => return key(.delete, modsOf(params[1]), length),
            4, 8 => return key(.end, modsOf(params[1]), length),
            200 => return .{ .event = .paste_start, .len = length },
            201 => return .{ .event = .paste_end, .len = length },
            else => {},
        },
        else => {},
    }

    // Some other CSI. Skip it rather than choking: a terminal sends responses
    // nobody asked for, and dropping one unknown sequence beats desynchronising
    // the whole stream.
    return .{ .event = .incomplete, .len = length };
}

fn parseByte(input: []const u8) ?Parsed {
    switch (input[0]) {
        '\r', '\n' => return key(.enter, .{}, 1),
        '\t' => return key(.tab, .{}, 1),
        // Both codes terminals send for the key marked Backspace.
        0x7f, 0x08 => return key(.backspace, .{}, 1),
        else => {},
    }

    // Control characters: Ctrl+A is 1, and so on up to Ctrl+Z. Reported as the
    // letter with a modifier rather than as its own kind of key, so a handler
    // that wants Ctrl+C and one that wants "c" read the same way.
    if (input[0] < 0x20) {
        return key(.{ .char = .init(&.{input[0] + 'a' - 1}) }, .{ .ctrl = true }, 1);
    }

    const length = std.unicode.utf8ByteSequenceLength(input[0]) catch 1;
    if (input.len < length) return .{ .event = .incomplete, .len = 0 };
    return key(.{ .char = .init(input[0..length]) }, .{}, length);
}

/// `ESC O X`, application cursor mode.
fn parseSs3(input: []const u8) ?Parsed {
    if (input.len < 3) return .{ .event = .incomplete, .len = 0 };
    return switch (input[2]) {
        'A' => key(.up, .{}, 3),
        'B' => key(.down, .{}, 3),
        'C' => key(.right, .{}, 3),
        'D' => key(.left, .{}, 3),
        'H' => key(.home, .{}, 3),
        'F' => key(.end, .{}, 3),
        else => .{ .event = .incomplete, .len = 3 },
    };
}

fn key(code: Event.Key.Code, mods: Event.Key.Mods, length: usize) Parsed {
    return .{ .event = .{ .key = .{ .code = code, .mods = mods } }, .len = length };
}

/// The modifier parameter terminals send: one plus a bit per held modifier.
///
/// Zero means the parameter was absent, which is not the same as "no
/// modifiers" arithmetically - subtracting one from it would set every bit.
fn modsOf(param: u16) Event.Key.Mods {
    if (param == 0) return .{};
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
                    if (in.len < capacity) return null;
                    in.discard(1);
                    in.dropped += 1;
                    continue;
                }
                in.discard(parsed.len);
                if (parsed.event == .incomplete) continue;
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
    var fields: [3]u16 = .{ 0, 0, 0 };
    var field: usize = 0;

    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= '0' and byte <= '9') {
            fields[field] = fields[field] *| 10 +| (byte - '0');
            continue;
        }
        if (byte == ';') {
            field += 1;
            if (field >= fields.len) return .{ .event = .incomplete, .len = index + 1 };
            continue;
        }
        if (byte != 'M' and byte != 'm') return .{ .event = .incomplete, .len = index + 1 };

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

        return .{ .event = .{ .mouse = .{ .x = x, .y = y, .kind = kind } }, .len = index + 1 };
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

test "coordinates past 223 survive, which the older encoding cannot" {
    try expectMouse("\x1b[<0;300;120M", 299, 119, .press);
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
        _ = screen.buffer().writeText(screen.buffer().area(), 0, 0, "hello", .{});
        const stats = try screen.flush(&w);
        try testing.expectEqual(@as(usize, 40 * 10), stats.cells);
    }

    { // Redrawing the same thing costs nothing at all.
        var w = Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), 0, 0, "hello", .{});
        const stats = try screen.flush(&w);
        try testing.expectEqual(@as(usize, 0), stats.cells);
    }

    { // One changed word costs one word.
        var w = Io.Writer.fixed(&out);
        screen.buffer().clear(.{});
        _ = screen.buffer().writeText(screen.buffer().area(), 0, 0, "world", .{});
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

    var newlines: usize = 0;
    var enters: usize = 0;
    while (at < paste.len) {
        const parsed = parse(paste[at..]).?;
        at += parsed.len;
        switch (parsed.event) {
            .paste_end => break,
            .key => |k| switch (k.code) {
                // The newline still parses as `enter`; what makes it text is
                // that the client knows a paste is in progress.
                .enter => enters += 1,
                .char => newlines += 1,
                else => {},
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), enters);
    try testing.expectEqual(@as(usize, 6), newlines);
    try testing.expect(at == paste.len);
}

test "a partial paste marker asks for more bytes" {
    try testing.expectEqual(@as(usize, 0), parse("\x1b[200").?.len);
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
        if (took == 0 and in.len == 0) return error.Stuck;
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
