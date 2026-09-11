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

const vt = @import("ghostty-vt");
const std = @import("std");
const Signal = @import("telar-core").Signal;
const Sample = @import("Sample.zig");
const builtin_table_module = @import("telar-core").builtin_table;
const Status = @import("telar-core").Status;
const AgentProviderType = @import("telar-core").AgentProvider;

fn testTerminal(cols: u16, rows: u16) !vt.Terminal {
    return vt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = cols, .rows = rows });
}

fn sampleSignal(terminal: *const vt.Terminal) ?Signal {
    var sample: Sample = .{};
    sample.capture(terminal);
    return sample.signal(&builtin_table_module);
}

test "a status line above the idle prompt keeps Codex working" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("• Working (12s • esc to interrupt)\n\nAsk Codex to do anything");

    const detected = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.working, detected.status);
    try std.testing.expectEqual(AgentProviderType.codex, detected.provider);
}

test "the idle prompt alone marks Codex ready" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("OpenAI Codex\n\nAsk Codex to do anything");

    const detected = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.ready, detected.status);
    try std.testing.expectEqual(AgentProviderType.codex, detected.provider);
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
    try std.testing.expectEqual(AgentProviderType.codex, detected.provider);
}

test "permission prompts outrank work and the prompt" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("Claude\nDo you want to proceed?\nesc to interrupt");

    const detected = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.blocked, detected.status);
    try std.testing.expectEqual(AgentProviderType.claude, detected.provider);
}

test "Claude branding confirms identity without claiming a prompt" {
    var terminal = try testTerminal(60, 6);
    defer terminal.deinit(std.testing.allocator);
    try terminal.printString("Claude Code v2.1");

    const branded = sampleSignal(&terminal).?;
    try std.testing.expectEqual(Status.ready, branded.status);
    try std.testing.expectEqual(AgentProviderType.claude, branded.provider);
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

    const detected = sample.signal(&builtin_table_module).?;
    try std.testing.expectEqual(Status.working, detected.status);
    try std.testing.expectEqual(AgentProviderType.codex, detected.provider);
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

    const detected = sample.signal(&builtin_table_module).?;
    try std.testing.expectEqual(Status.ready, detected.status);
    try std.testing.expectEqual(AgentProviderType.codex, detected.provider);
}
