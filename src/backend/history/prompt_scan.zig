//! Screen scans that read an agent's idle prompt off the live terminal.
//!
//! A manifest phrase can prove readiness only when the agent prints a fixed
//! sentence. Claude Code prints a bare `❯`, which is meaningful only in the
//! emulator's current screen: a copy found in raw PTY bytes may have been
//! erased or moved before the batch finished. Such scans need the terminal
//! and therefore live here, on the observation path, rather than in the
//! manifest table. Each scan is one function tagged with the agent it reads;
//! a configured agent has none and relies on its manifest phrases.

const core = @import("telar-core");
const vt = @import("ghostty-vt");
const std = @import("std");

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
pub fn scanReadyPrompt(terminal: *const vt.Terminal) ?core.Signal {
    for (scans) |scan| {
        if (!scan.ready(terminal)) {
            continue;
        }

        return .{
            .provider = scan.provider,
            .status = .ready,
            .confidence = scan.confidence,
            .ready_confirmed = true,
        };
    }

    return null;
}

/// Whether an idle agent's composer holds a draft, such as the unanswered
/// prompt Claude Code puts back when its turn is interrupted. Only Claude
/// Code is read: its title swaps the working spinner for `✳` once the turn
/// stopped, and the composer's prompt row then carries typed text. The dim
/// placeholder Claude shows in an empty composer is not a draft.
///
/// ```zig
/// if (prompt_scan.showsRestoredDraft(&pane.terminal, .claude)) clearDraft();
/// ```
pub fn showsRestoredDraft(terminal: *const vt.Terminal, provider: core.AgentProvider) bool {
    if (provider != .claude or claudeTitle(terminal) != .idle) {
        return false;
    }

    const screen = terminal.screens.active;
    const rows = terminal.rows;
    var y: usize = rows;
    while (y > rows - @min(rows, max_prompt_rows)) {
        y -= 1;
        const pin = screen.pages.pin(.{ .viewport = .{ .y = @intCast(y) } }) orelse continue;
        const cells = pin.cells(.all);
        for (cells, 0..) |*cell, x| {
            if (cell.codepoint() != claude_prompt or !rowPrefixIsBlank(cells[0..x])) {
                continue;
            }

            // The lowest row that starts with `❯` is the composer; earlier
            // ones quote prompts in the transcript.
            for (cells[x + 1 ..]) |*typed| {
                if (typed.hasText() and !isBlank(typed.codepoint()) and !pin.style(typed).flags.faint) {
                    return true;
                }
            }

            return false;
        }
    }

    return false;
}

/// What Claude Code's terminal title says about its turn. Claude Code 2.1.283
/// animates `◐` and `◑` in front of the title while a turn runs and shows
/// `✳` otherwise (`u5=["◐","◑"],p5="✳"` in its bundle). Any
/// other title was not set by Claude, say a shell's, and says nothing.
const ClaudeTitle = enum { unknown, idle, working };

fn claudeTitle(terminal: *const vt.Terminal) ClaudeTitle {
    const title = terminal.getTitle() orelse return .unknown;
    if (std.mem.startsWith(u8, title, claude_idle_title)) {
        return .idle;
    }

    for (claude_working_titles) |spinner| {
        if (std.mem.startsWith(u8, title, spinner)) {
            return .working;
        }
    }

    return .unknown;
}

fn isBlank(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == no_break_space;
}

const claude_idle_title = "\u{2733}";
const claude_working_titles = [_][]const u8{ "\u{25d0}", "\u{25d1}" };
const claude_prompt: u21 = 0x276f;
/// Claude Code writes it between `❯` and the composer text.
const no_break_space: u21 = 0x00a0;
const max_prompt_rows = 12;

/// Claude may use either the terminal cursor or an inverse-video cell as its
/// editor cursor. In both cases the cursor must belong to the prompt row,
/// which excludes the stale input row Claude leaves behind while it is working.
/// Claude Code keeps its composer on screen during a turn, so a title that
/// shows the working spinner rules readiness out.
fn claudeReadyPrompt(terminal: *const vt.Terminal) bool {
    if (claudeTitle(terminal) == .working) {
        return false;
    }

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
        if (!cell.hasText()) {
            continue;
        }
        const codepoint = cell.codepoint();
        if (isBlank(codepoint)) {
            continue;
        }
        return codepoint == claude_prompt;
    }
    return false;
}

fn promptWithSoftwareCursor(screen: *const vt.Screen, rows: u16) bool {
    const first_row = rows - @min(rows, max_prompt_rows);
    for (first_row..rows) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .y = @intCast(y) } }) orelse
            continue;
        const cells = pin.cells(.all);
        var prompt: ?usize = null;
        for (cells, 0..) |*cell, x| {
            if (cell.codepoint() == claude_prompt and rowPrefixIsBlank(cells[0..x])) {
                prompt = x;
                continue;
            }
            if (prompt == null or x <= prompt.?) {
                continue;
            }
            if (cell.content_tag == .bg_color_palette or cell.content_tag == .bg_color_rgb) {
                return true;
            }
            const cell_style = pin.style(cell);
            if (cell_style.flags.inverse or hasBackground(cell_style.bg_color)) {
                return true;
            }
        }
    }
    return false;
}

fn rowPrefixIsBlank(cells: []const vt.Cell) bool {
    for (cells) |cell| {
        if (cell.hasText() and !isBlank(cell.codepoint())) {
            return false;
        }
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

const Scan = struct {
    provider: core.AgentProvider,
    confidence: u8,
    ready: *const fn (terminal: *const vt.Terminal) bool,
};
