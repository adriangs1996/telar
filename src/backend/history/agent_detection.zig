//! Bounded screen sampling for agent heuristics.
//!
//! Manifest phrases describe what an agent shows, so they are matched against
//! the history emulator's active screen rather than the raw byte stream. A
//! client that repaints only the cells that changed, as Codex and Claude Code
//! do, can emit its idle prompt in one batch without the status line that is
//! still drawn above it. The screen holds both, and `Table.detect` ranks a
//! visible blocked or working phrase above the prompt. Codex uses the separate
//! `codex_screen` scan in Observer, because its transcript can quote these
//! phrases and its live composer also accepts nonempty drafts.
//!
//! These patterns are presentation hints only. They may mark a pane as busy or
//! visibly blocked; they never grant permission or generate input.

const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");

const schema = core.schema;

pub const Status = core.agent_manifest.Status;
pub const Signal = core.agent_manifest.Signal;
pub const Table = core.agent_manifest.Table;

/// Plain text of the active screen, captured bottom-up so the rows nearest
/// the prompt are complete whenever the screen exceeds the capacity.
pub const Sample = struct {
    pub const capacity = 16 * 1024;

    bytes: [capacity]u8 = undefined,
    start: usize = capacity,

    /// Replaces the sample with the terminal's current active screen. Blank
    /// cells become spaces, a hard line break becomes one space and a
    /// soft-wrapped row continues into the next one without a separator.
    ///
    /// ```zig
    /// sample.capture(&observer.terminal);
    /// const signal = sample.signal(observer.manifests);
    /// ```
    pub fn capture(sample: *Sample, terminal: *const vt.Terminal) void {
        sample.start = capacity;
        const screen = terminal.screens.active;
        var y: usize = terminal.rows;

        while (y != 0) {
            y -= 1;
            const pin = screen.pages.pin(.{ .active = .{ .y = @intCast(y) } }) orelse continue;

            if (sample.start != capacity and !pin.rowAndCell().row.wrap) {
                if (!sample.prepend(" ")) {
                    return;
                }
            }

            if (!sample.prependRow(pin.cells(.all))) {
                return;
            }
        }
    }

    pub fn text(sample: *const Sample) []const u8 {
        return sample.bytes[sample.start..];
    }

    /// Applies the manifest table's heuristics to the captured screen.
    ///
    /// ```zig
    /// const signal = sample.signal(&core.agent_manifest.builtin_table);
    /// ```
    pub fn signal(sample: *const Sample, table: *const Table) ?Signal {
        return table.detect(sample.text());
    }

    fn prependRow(sample: *Sample, cells: []const vt.Cell) bool {
        var index = cells.len;
        while (index != 0 and cells[index - 1].codepoint() == 0) : (index -= 1) {}

        while (index != 0) {
            index -= 1;
            const codepoint = cells[index].codepoint();

            if (codepoint == 0) {
                if (!sample.prepend(" ")) {
                    return false;
                }
                continue;
            }

            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &encoded) catch replaced: {
                encoded[0] = '?';
                break :replaced 1;
            };

            if (!sample.prepend(encoded[0..len])) {
                return false;
            }
        }

        return true;
    }

    fn prepend(sample: *Sample, bytes: []const u8) bool {
        if (bytes.len > sample.start) {
            return false;
        }

        sample.start -= bytes.len;
        @memcpy(sample.bytes[sample.start..][0..bytes.len], bytes);
        return true;
    }
};

fn testTerminal(cols: u16, rows: u16) !vt.Terminal {
    return vt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = cols, .rows = rows });
}

fn sampleSignal(terminal: *const vt.Terminal) ?Signal {
    var sample: Sample = .{};
    sample.capture(terminal);
    return sample.signal(&core.agent_manifest.builtin_table);
}

test "a status line above the idle prompt keeps Codex working" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("• Working (12s • esc to interrupt)\n\nAsk Codex to do anything");

    const detected = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.working, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
}

test "the idle prompt alone marks Codex ready" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("OpenAI Codex\n\nAsk Codex to do anything");

    const detected = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.ready, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
    try std.testing.expect(detected.identity_confirmed);
    try std.testing.expect(detected.ready_confirmed);
}

test "an erased status line no longer counts" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("• Working (12s • esc to interrupt)\n\nAsk Codex to do anything");
    terminal.setCursorPos(1, 1);
    terminal.eraseLine(.complete, false);

    const detected = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.ready, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
}

test "permission prompts outrank work and the prompt" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("Claude\nDo you want to proceed?\nesc to interrupt");

    const detected = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.blocked, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, detected.provider);
}

test "Claude branding confirms identity without claiming a prompt" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("Claude Code v2.1");

    const branded = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.ready, branded.status);
    try std.testing.expectEqual(schema.AgentProvider.claude, branded.provider);
    try std.testing.expect(branded.identity_confirmed);
    try std.testing.expect(!branded.ready_confirmed);
}

test "soft-wrapped rows join without a separator" {
    var terminal = try testTerminal(10, 4);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("Codex esc to interrupt");

    var sample: Sample = .{};
    sample.capture(&terminal);
    try std.testing.expectEqualStrings("Codex esc to interrupt", sample.text());

    const detected = sample.signal(&core.agent_manifest.builtin_table).?;
    try std.testing.expectEqual(Status.working, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
}

test "hard line breaks separate rows and blank cells become spaces" {
    var terminal = try testTerminal(8, 4);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("esc\nto  x");

    var sample: Sample = .{};
    sample.capture(&terminal);
    try std.testing.expectEqualStrings("esc to  x", sample.text());
}

test "the bottom rows survive a screen larger than the capacity" {
    var terminal = try testTerminal(200, 100);
    defer terminal.deinit(std.testing.allocator);
    const filler: [200]u8 = @splat('x');

    for (0..99) |_| {
        try terminal.printString(&filler);
        try terminal.printString("\n");
    }
    try terminal.printString("Ask Codex to do anything");

    var sample: Sample = .{};
    sample.capture(&terminal);
    try std.testing.expect(sample.text().len <= Sample.capacity);
    try std.testing.expect(std.mem.endsWith(u8, sample.text(), "Ask Codex to do anything"));

    const detected = sample.signal(&core.agent_manifest.builtin_table).?;
    try std.testing.expectEqual(Status.ready, detected.status);
    try std.testing.expectEqual(schema.AgentProvider.codex, detected.provider);
}
