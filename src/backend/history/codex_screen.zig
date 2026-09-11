//! Codex's live composer and the status rows immediately above it. Transcript
//! text is never a ready prompt, even when it quotes the complete placeholder.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");

const Signal = core.agent_manifest.Signal;
const max_rows = 32;

const Row = @import("Row.zig");

/// Reads bounded terminal chrome. The cursor must belong to the composer to
/// prove readiness; the placeholder only confirms identity. A draft works too.
///
/// ```zig
/// const signal = codex_screen.scan(terminal, manifests);
/// ```
pub fn scan(terminal: *const vt.Terminal, manifests: *const core.agent_manifest.Table) ?Signal {
    const first_row = terminal.rows - @min(terminal.rows, max_rows);
    var y: usize = terminal.rows;
    while (y > first_row) {
        y -= 1;
        const prompt = Row.read(terminal, y);
        if (prompt.first != 0x203a or prompt.column > 1) {
            continue;
        }

        const manifest = manifests.find(.codex) orelse return null;
        const identified = manifest.ready_prompt.matches(prompt.text());
        var above = y;
        while (above > first_row) {
            above -= 1;
            const row = Row.read(terminal, above);
            // Codex commits the completed turn above this horizontal rule.
            if (row.first == 0x2500) {
                break;
            }

            if (row.isStatus()) {
                return .{ .provider = .codex, .status = .working, .confidence = 94, .identity_confirmed = identified };
            }
        }

        const cursor = terminal.screens.active.cursor;
        if (!terminal.modes.get(.cursor_visible) or cursor.y < y or cursor.x < prompt.column + 2) {
            return null;
        }

        for (y + 1..@as(usize, cursor.y) + 1) |continuation| {
            const row = Row.read(terminal, continuation);
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
        try std.testing.expectEqual(core.agent_manifest.Status.working, scan(&terminal, &core.agent_manifest.builtin_table).?.status);
    }
}

test "Codex composer drafts prove readiness without claiming identity" {
    var terminal = try vt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 80, .rows = 12 });
    defer terminal.deinit(std.testing.allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("\xe2\x80\xba my next question\r\n  continued draft");

    const signal = scan(&terminal, &core.agent_manifest.builtin_table).?;
    try std.testing.expect(signal.ready_confirmed);
    try std.testing.expect(!signal.identity_confirmed);
    stream.nextSlice("\x1b[?25l");
    try std.testing.expect(scan(&terminal, &core.agent_manifest.builtin_table) == null);
}
