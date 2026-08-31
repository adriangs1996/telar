//! Platform adapter for one host-audio worker.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const Io = std.Io;
const Kind = types.Kind;

const playback_timeout: Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(3) },
};

/// Plays one semantic sound through the current host audio adapter.
///
/// ```zig
/// try play(io, .ready);
/// ```
pub fn play(io: Io, kind: Kind) !void {
    switch (builtin.os.tag) {
        .macos => if (!commandSucceeded(io, &.{
            "/usr/bin/afplay",
            switch (kind) {
                .ready => "/System/Library/Sounds/Glass.aiff",
                .needs_input => "/System/Library/Sounds/Ping.aiff",
            },
        })) {
            return error.SoundUnavailable;
        },
        .linux => try playLinux(io, kind),
        .windows => {
            const message_type: u32 = switch (kind) {
                .ready => 0x00000040, // MB_ICONASTERISK
                .needs_input => 0x00000030, // MB_ICONEXCLAMATION
            };
            if (Windows.MessageBeep(message_type) == 0) {
                return error.SoundUnavailable;
            }
        },
        else => return error.SoundUnavailable,
    }
}

fn playLinux(io: Io, kind: Kind) !void {
    const event = switch (kind) {
        .ready => "complete",
        .needs_input => "dialog-warning",
    };
    if (commandSucceeded(io, &.{ "canberra-gtk-play", "--id", event })) {
        return;
    }

    const file = switch (kind) {
        .ready => "/usr/share/sounds/freedesktop/stereo/complete.oga",
        .needs_input => "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga",
    };
    if (commandSucceeded(io, &.{ "paplay", file })) {
        return;
    }
    if (commandSucceeded(io, &.{ "pw-play", file })) {
        return;
    }
    if (commandSucceeded(io, &.{
        "ffplay",
        "-nodisp",
        "-autoexit",
        "-loglevel",
        "quiet",
        file,
    })) {
        return;
    }
    if (commandSucceeded(io, &.{ "mpv", "--no-video", "--really-quiet", file })) {
        return;
    }

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

test {
    std.testing.refAllDecls(@This());
}
