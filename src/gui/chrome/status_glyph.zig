//! One glyph and one palette role per agent status, shared by every chrome
//! surface that shows attention (decisions 6 and P2 of the visual language).
const std = @import("std");
const core = @import("telar-core");
const Palette = @import("telar-client").Palette;

/// The status glyph; a blocked agent shows why it waits.
/// Example: `const text = status_glyph.glyph(.blocked, .permission); // "⚠"`
pub fn glyph(status: core.AgentStatus, reason: core.AgentBlockedReason) []const u8 {
    return switch (status) {
        .blocked => switch (reason) {
            .permission => "\u{26a0}",
            .question => "?",
            .plan => "\u{2261}",
            .none, .other => "!",
        },
        .working => "\u{25cc}",
        .done => "\u{2713}",
        .failed => "\u{2715}",
        .ready => "\u{00b7}",
        .unknown => "?",
    };
}

/// The palette role of a status: blocked yellow, working teal, done green,
/// failed red, idle and unknown `overlay1`.
/// Example: `const ink = status_glyph.color(palette, agent.status);`
pub fn color(palette: Palette, status: core.AgentStatus) core.Color {
    return switch (status) {
        .working => palette.teal,
        .done => palette.green,
        .blocked => palette.yellow,
        .failed => palette.red,
        .ready, .unknown => palette.overlay1,
    };
}

/// Alpha of the working glyph: six steps between 1.0 and 0.35 across 17
/// animation frames of 120 ms, so one pulse lasts about two seconds.
/// Example: `label.alpha = status_glyph.pulse(frame);`
pub fn pulse(frame: u8) f32 {
    const step: f32 = @floatFromInt((@as(u32, frame) % 17) * 6 / 17);
    const distance = @abs(step - 3);
    return 0.35 + 0.65 * distance / 3;
}

test "the pulse visits six alpha steps and never leaves its range" {
    var seen: [6]bool = @splat(false);
    for (0..255) |frame| {
        const alpha = pulse(@intCast(frame));
        try std.testing.expect(alpha >= 0.35 and alpha <= 1.0);
        const step = (@as(u32, @intCast(frame)) % 17) * 6 / 17;
        seen[step] = true;
    }

    for (seen) |value| {
        try std.testing.expect(value);
    }

    try std.testing.expectEqual(@as(f32, 1), pulse(0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), pulse(9), 0.0001);
}
