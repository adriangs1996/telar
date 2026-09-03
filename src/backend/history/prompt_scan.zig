//! Screen scans that read an agent's idle prompt off the live terminal.
//!
//! A manifest phrase can prove readiness only when the agent prints a fixed
//! sentence. Claude Code prints a bare `❯`, which is meaningful only in the
//! emulator's current screen: a copy found in raw PTY bytes may have been
//! erased or moved before the batch finished. Such scans need the terminal
//! and therefore live here, on the observation path, rather than in the
//! manifest table. Each scan is one function tagged with the agent it reads;
//! a configured agent has none and relies on its manifest phrases.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");

const Signal = core.agent_manifest.Signal;

const Scan = struct {
    provider: core.schema.AgentProvider,
    confidence: u8,
    ready: *const fn (terminal: *const vt.Terminal) bool,
};

const scans = [_]Scan{
    .{ .provider = .claude, .confidence = 96, .ready = claudeReadyPrompt },
};

/// Runs every scan against the live terminal and returns the first agent
/// whose idle prompt is visible. The signal confirms readiness, never
/// identity: a prompt glyph alone does not say which agent drew it.
///
/// ```zig
/// const screen_signal = prompt_scan.scanReadyPrompt(&observer.terminal);
/// ```
pub fn scanReadyPrompt(terminal: *const vt.Terminal) ?Signal {
    for (scans) |scan| {
        if (!scan.ready(terminal)) continue;

        return .{
            .provider = scan.provider,
            .status = .ready,
            .confidence = scan.confidence,
            .ready_confirmed = true,
        };
    }

    return null;
}

/// Claude may use either the terminal cursor or an inverse-video cell as its
/// editor cursor. In both cases the cursor must belong to the prompt row,
/// which excludes the stale input row Claude leaves behind while it is working.
fn claudeReadyPrompt(terminal: *const vt.Terminal) bool {
    const screen = terminal.screens.active;
    if (terminal.modes.get(.cursor_visible)) {
        return promptBeforeTerminalCursor(screen.cursor.page_pin.*);
    }

    return promptWithSoftwareCursor(screen, terminal.rows);
}

fn promptBeforeTerminalCursor(cursor: vt.Pin) bool {
    const cells = cursor.cells(.left);
    const max_prompt_distance = 8;
    var index = cells.len;
    var distance: usize = 0;
    while (index != 0 and distance < max_prompt_distance) : (distance += 1) {
        index -= 1;
        const cell = cells[index];
        if (!cell.hasText()) continue;
        const codepoint = cell.codepoint();
        if (codepoint == ' ') continue;
        return codepoint == 0x276f;
    }
    return false;
}

fn promptWithSoftwareCursor(screen: *const vt.Screen, rows: u16) bool {
    const max_prompt_rows = 12;
    const first_row = rows - @min(rows, max_prompt_rows);
    for (first_row..rows) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .y = @intCast(y) } }) orelse
            continue;
        const cells = pin.cells(.all);
        var prompt: ?usize = null;
        for (cells, 0..) |*cell, x| {
            if (cell.codepoint() == 0x276f and rowPrefixIsBlank(cells[0..x])) {
                prompt = x;
                continue;
            }
            if (prompt == null or x <= prompt.?) continue;
            if (cell.content_tag == .bg_color_palette or cell.content_tag == .bg_color_rgb)
                return true;
            const cell_style = pin.style(cell);
            if (cell_style.flags.inverse or hasBackground(cell_style.bg_color)) return true;
        }
    }
    return false;
}

fn rowPrefixIsBlank(cells: []const vt.Cell) bool {
    for (cells) |cell| {
        if (cell.hasText() and cell.codepoint() != ' ') return false;
    }
    return true;
}

fn hasBackground(color: vt.Style.Color) bool {
    return switch (color) {
        .none => false,
        .palette, .rgb => true,
    };
}

test {
    std.testing.refAllDecls(@This());
}
