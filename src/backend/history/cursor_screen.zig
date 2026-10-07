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
