//! Codex's live composer and the status rows immediately above it. Transcript
//! text is never a ready prompt, even when it quotes the complete placeholder.

const core = @import("telar-core");
const vt = @import("ghostty-vt");
const std = @import("std");
const ScreenRow = @import("ScreenRow.zig");

const max_rows = 32;

/// Reads bounded terminal chrome. The cursor must belong to the composer to
/// prove readiness; the placeholder only confirms identity. A draft works too.
///
/// ```zig
/// const signal = codex_screen.scan(terminal, manifests);
/// ```
pub fn scan(terminal: *const vt.Terminal, manifests: *const core.Table) ?core.Signal {
    const first_row = terminal.rows - @min(terminal.rows, max_rows);
    var y: usize = terminal.rows;
    while (y > first_row) {
        y -= 1;
        const prompt = ScreenRow.read(terminal, y);
        if (prompt.first != 0x203a or prompt.column > 1) {
            continue;
        }

        const manifest = manifests.find(.codex) orelse return null;
        const identified = manifest.ready_prompt.matches(prompt.text());
        var above = y;
        while (above > first_row) {
            above -= 1;
            const row = ScreenRow.read(terminal, above);
            // Codex commits the completed turn above this horizontal rule.
            if (row.first == 0x2500) {
                break;
            }

            if (isStatus(&row)) {
                return .{ .provider = .codex, .status = .working, .confidence = 94, .identity_confirmed = identified };
            }
        }

        const cursor = terminal.screens.active.cursor;
        if (!terminal.modes.get(.cursor_visible) or cursor.y < y or cursor.x < prompt.column + 2) {
            return null;
        }

        for (y + 1..@as(usize, cursor.y) + 1) |continuation| {
            const row = ScreenRow.read(terminal, continuation);
            if (row.first != 0 and row.column < prompt.column + 2) {
                return null;
            }
        }

        return .{
            .provider = .codex,
            .status = .ready,
            .confidence = 94,
            .identity_confirmed = identified,
            .ready_confirmed = true,
        };
    }

    return null;
}

test "Codex status clocks support remapped shortcuts and disabled animations" {
    for ([_][]const u8{ "Working (2s)", "Thinking (1m 03s, f12 to interrupt)", "Working (2h 01m 03s)", "Working (1s" }) |text| {
        var terminal = try vt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 100, .rows = 12 });
        defer terminal.deinit(std.testing.allocator);
        var stream = terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice(text);
        stream.nextSlice("\r\n\r\n\xe2\x80\xba Ask Codex to do anything\x1b[3G");
        try std.testing.expectEqual(core.Status.working, scan(&terminal, &core.builtin_table).?.status);
    }
}

test "Codex composer drafts prove readiness without claiming identity" {
    var terminal = try vt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 80, .rows = 12 });
    defer terminal.deinit(std.testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("\xe2\x80\xba my next question\r\n  continued draft");

    const signal = scan(&terminal, &core.builtin_table).?;
    try std.testing.expect(signal.ready_confirmed);
    try std.testing.expect(!signal.identity_confirmed);
    stream.nextSlice("\x1b[?25l");
    try std.testing.expect(scan(&terminal, &core.builtin_table) == null);
}

// A status row starts with a spinner or a known heading and carries a clock.
fn isStatus(row: *const ScreenRow) bool {
    const line = row.text();
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return false;
    const heading = std.mem.trim(u8, line[0..open], " ");
    const spinner = row.first == 0x2022 or (row.first >= 0x2800 and row.first <= 0x28ff);
    if (!spinner and !std.mem.eql(u8, heading, "Working") and !std.mem.eql(u8, heading, "Thinking") and !std.mem.eql(u8, heading, "Reconnecting") and !std.mem.eql(u8, heading, "Compacting")) {
        return false;
    }

    // A clock is part of the live status contract, including when the
    // interrupt shortcut is remapped, hidden, or clipped by a narrow pane.
    var index = open + 1;
    const digits = index;
    while (index < line.len and std.ascii.isDigit(line[index])) : (index += 1) {}
    if (index == digits or index == line.len) {
        return false;
    }

    return line[index] == 's' or line[index] == 'm' or line[index] == 'h';
}
