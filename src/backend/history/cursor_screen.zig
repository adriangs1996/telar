//! Cursor Agent's composer and the spinner row that heads a running turn.
//! Traced frame by frame on Cursor Agent 2026.09.26: a turn draws a braille
//! spinner ("⠀⠞ Working", "⠘⠣ Running  245 tokens") above the composer from
//! its first frame, and "ctrl+c to stop" joins the composer row a moment
//! later. An idle composer shows neither. A frame without the composer, such
//! as one Cursor has not finished painting, proves nothing. Approval and
//! plan dialogs draw their options with the same arrow, so their blocked
//! phrases must be matched before this scan.

const core = @import("telar-core");
const vt = @import("ghostty-vt");
const std = @import("std");
const ScreenRow = @import("ScreenRow.zig");

/// Bottom rows the scan reads; the composer and its footer sit well inside.
const max_rows = 32;
/// Rows between the spinner and the composer: a tip and the box's top edge
/// sit in between.
const max_spinner_distance = 6;
/// The composer's arrow sits after a margin of at most this many columns.
const max_composer_column = 3;
const composer_mark: u21 = 0x2192;
const first_braille: u21 = 0x2800;
const last_braille: u21 = 0x28ff;
const stop_hint = "ctrl+c to stop";
const placeholders = [_][]const u8{ "Add a follow-up", "Plan, search, build anything" };

/// Reads the composer closest to the bottom of the screen: `working` while a
/// spinner or the stop hint accompanies it, `ready` otherwise. The empty
/// composer's placeholder confirms identity; a draft does not.
///
/// ```zig
/// const signal = cursor_screen.scan(terminal) orelse return;
/// ```
pub fn scan(terminal: *const vt.Terminal) ?core.Signal {
    const first_row = terminal.rows - @min(terminal.rows, max_rows);
    var y: usize = terminal.rows;
    while (y > first_row) {
        y -= 1;
        const composer = ScreenRow.read(terminal, y);
        if (composer.first != composer_mark or composer.column > max_composer_column) {
            continue;
        }

        const draft = composer.text();
        const identified = isPlaceholder(draft);
        if (std.mem.indexOf(u8, draft, stop_hint) != null or spinnerAbove(terminal, y, first_row)) {
            return .{ .provider = .cursor, .status = .working, .confidence = 94, .identity_confirmed = identified };
        }

        return .{
            .provider = .cursor,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = identified,
            .ready_confirmed = true,
        };
    }

    return null;
}

fn spinnerAbove(terminal: *const vt.Terminal, composer: usize, first_row: usize) bool {
    const top = @max(first_row, composer -| max_spinner_distance);
    var y = composer;
    while (y > top) {
        y -= 1;
        const row = ScreenRow.read(terminal, y);
        const label = row.text();
        if (row.first >= first_braille and row.first <= last_braille and label.len != 0 and std.ascii.isAlphabetic(label[0])) {
            return true;
        }
    }

    return false;
}

fn isPlaceholder(draft: []const u8) bool {
    for (placeholders) |placeholder| {
        if (std.mem.startsWith(u8, draft, placeholder)) {
            return true;
        }
    }

    return false;
}

fn testTerminal() !vt.Terminal {
    return vt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 100, .rows = 16 });
}

fn feed(terminal: *vt.Terminal, text: []const u8) void {
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice(text);
}

test "the spinner marks a running turn from its first frame, before the stop hint" {
    var first = try testTerminal();
    defer first.deinit(std.testing.allocator);
    feed(&first, "  Tip: Hit shift+tab to enable Plan Mode.\r\n \xe2\xa0\x80\xe2\xa0\x9e Working\r\n\r\n  \xe2\x86\x92 Plan, search, build anything\r\n\r\n  Auto");
    const starting = scan(&first).?;
    try std.testing.expectEqual(core.Status.working, starting.status);
    try std.testing.expect(starting.identity_confirmed);

    var later = try testTerminal();
    defer later.deinit(std.testing.allocator);
    feed(&later, " \xe2\xa0\x98\xe2\xa0\xa3 Running  245 tokens\r\n    Tip: Use /config to customize Cursor.\r\n \xe2\x96\x84\xe2\x96\x84\xe2\x96\x84\r\n  \xe2\x86\x92 Add a follow-up        ctrl+c to stop\r\n \xe2\x96\x80\xe2\x96\x80\xe2\x96\x80\r\n  Auto \xc2\xb7 7%");
    try std.testing.expectEqual(core.Status.working, scan(&later).?.status);

    var hint_only = try testTerminal();
    defer hint_only.deinit(std.testing.allocator);
    feed(&hint_only, "  \xe2\x86\x92 Add a follow-up        ctrl+c to stop\r\n  Auto");
    try std.testing.expectEqual(core.Status.working, scan(&hint_only).?.status);
}

test "an idle composer proves readiness and a draft proves it without identity" {
    var idle = try testTerminal();
    defer idle.deinit(std.testing.allocator);
    feed(&idle, "  finished\r\n\r\n \xe2\x96\x84\xe2\x96\x84\xe2\x96\x84\r\n  \xe2\x86\x92 Add a follow-up\r\n \xe2\x96\x80\xe2\x96\x80\xe2\x96\x80\r\n  Auto \xc2\xb7 7%\r\n  ~/sandbox/telar \xc2\xb7 main");
    const ready = scan(&idle).?;
    try std.testing.expectEqual(core.Status.ready, ready.status);
    try std.testing.expect(ready.ready_confirmed);
    try std.testing.expect(ready.identity_confirmed);

    var draft = try testTerminal();
    defer draft.deinit(std.testing.allocator);
    feed(&draft, "  \xe2\x86\x92 Read notes.txt and edit.txt\r\n  Auto");
    const typing = scan(&draft).?;
    try std.testing.expectEqual(core.Status.ready, typing.status);
    try std.testing.expect(!typing.identity_confirmed);
}

test "a frame without the composer and a spinner far above it prove nothing" {
    var partial = try testTerminal();
    defer partial.deinit(std.testing.allocator);
    feed(&partial, " \xe2\xa0\xa0\xe2\xa0\x9c Working  5 tokens\r\n  Explored 2 files");
    try std.testing.expect(scan(&partial) == null);

    var transcript = try testTerminal();
    defer transcript.deinit(std.testing.allocator);
    feed(&transcript, " \xe2\xa0\x80\xe2\xa0\x9e Working\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n  \xe2\x86\x92 Add a follow-up");
    try std.testing.expectEqual(core.Status.ready, scan(&transcript).?.status);

    var indented = try testTerminal();
    defer indented.deinit(std.testing.allocator);
    feed(&indented, "      \xe2\x86\x92 an arrow in the transcript");
    try std.testing.expect(scan(&indented) == null);
}
