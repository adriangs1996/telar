//! Client-local playback for semantic agent notification sounds.
//!
//! The runtime decides that a transition happened. This module owns the host
//! side effect because a headless or remote runtime has no useful audio
//! device. Playback runs as an observation task and never blocks drawing,
//! input, PTY forwarding, or another client.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("telar-core");

const Io = std.Io;
pub const Kind = core.schema.AgentSound;

const playback_timeout: Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(3) },
};

pub fn coalesce(current: ?Kind, incoming: Kind) Kind {
    if (current == .needs_input or incoming == .needs_input) return .needs_input;
    return .ready;
}

pub fn play(io: Io, kind: Kind) !void {
    switch (builtin.os.tag) {
        .macos => if (!commandSucceeded(io, &.{
            "/usr/bin/afplay",
            switch (kind) {
                .ready => "/System/Library/Sounds/Glass.aiff",
                .needs_input => "/System/Library/Sounds/Ping.aiff",
            },
        })) return error.SoundUnavailable,
        .linux => try playLinux(io, kind),
        .windows => {
            const message_type: u32 = switch (kind) {
                .ready => 0x00000040, // MB_ICONASTERISK
                .needs_input => 0x00000030, // MB_ICONEXCLAMATION
            };
            if (Windows.MessageBeep(message_type) == 0) return error.SoundUnavailable;
        },
        else => return error.SoundUnavailable,
    }
}

fn playLinux(io: Io, kind: Kind) !void {
    const event = switch (kind) {
        .ready => "complete",
        .needs_input => "dialog-warning",
    };
    if (commandSucceeded(io, &.{ "canberra-gtk-play", "--id", event })) return;

    const file = switch (kind) {
        .ready => "/usr/share/sounds/freedesktop/stereo/complete.oga",
        .needs_input => "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga",
    };
    if (commandSucceeded(io, &.{ "paplay", file })) return;
    if (commandSucceeded(io, &.{ "pw-play", file })) return;
    if (commandSucceeded(io, &.{
        "ffplay",
        "-nodisp",
        "-autoexit",
        "-loglevel",
        "quiet",
        file,
    })) return;
    if (commandSucceeded(io, &.{ "mpv", "--no-video", "--really-quiet", file })) return;
    return error.SoundUnavailable;
}

fn commandSucceeded(io: Io, argv: []const []const u8) bool {
    const gpa = std.heap.page_allocator;
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = playback_timeout,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |status| status == 0,
        else => false,
    };
}

const Windows = struct {
    extern "user32" fn MessageBeep(message_type: u32) callconv(.winapi) i32;
};

test "needs-input sounds win when a burst is coalesced" {
    try std.testing.expectEqual(Kind.ready, coalesce(null, .ready));
    try std.testing.expectEqual(Kind.needs_input, coalesce(.ready, .needs_input));
    try std.testing.expectEqual(Kind.needs_input, coalesce(.needs_input, .ready));
}

test {
    std.testing.refAllDecls(@This());
}
