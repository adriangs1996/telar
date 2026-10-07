//! One runtime pane: its process, PTY, emulator, buffers, and quotas.
//!
//! Split out of `runtime.zig`; ownership rules are unchanged. The runtime
//! event loop drives these panes through `PaneStore`. Actor results cross back
//! into that owner as `PaneKey` values, never as mutable pane pointers.

const core = @import("telar-core");
const std = @import("std");
const cmdcapture = @import("cmdcapture");
const Clock = cmdcapture.Clock;

pub const output_chunk_size = 16 * 1024;

pub const max_pty_response_bytes = 1024;

pub const max_pty_responses = 64;

/// Retained VT history per pane. This matches herdr's default and stays a byte
/// quota so wide, styled terminal rows are charged for what they retain.
pub const default_scrollback_bytes = 10_000_000;

/// How long a child's synchronized-output block (DEC mode 2026) may hold
/// frames back before it is ignored. Same value ghostty uses to reset the
/// mode when a program forgets to close its block.
pub const max_sync_hold_ns = 1000 * std.time.ns_per_ms;

pub const LaunchState = enum {
    starting,
    running,
    aborting,

    pub fn commit(self: *LaunchState) void {
        std.debug.assert(self.* == .starting);
        self.* = .running;
    }

    pub fn abort(self: *LaunchState) void {
        std.debug.assert(self.* == .starting);
        self.* = .aborting;
    }

    pub fn discoverable(self: LaunchState) bool {
        return self == .running;
    }
};

pub const PtyWriteResult = enum {
    succeeded,
    failed,
};

pub const PtyOutputReadResult = enum {
    data,
    finished,
};

pub fn sanitizeTitle(storage: *[core.max_pane_title_bytes]u8, raw: []const u8) usize {
    var len: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(raw);
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |sequence| {
        if (sequence.len == 1 and (sequence[0] < 0x20 or sequence[0] == 0x7f)) {
            continue;
        }
        if (!std.unicode.utf8ValidateSlice(sequence)) {
            continue;
        }
        if (len + sequence.len > storage.len) {
            break;
        }

        @memcpy(storage[len .. len + sequence.len], sequence);
        len += sequence.len;
    }

    return len;
}

pub const ScreenResize = @import("ScreenResize.zig");

/// Resizes the cell grid and its per-row damage flags together.
///
/// The two lengths are one invariant: `blit` writes `damaged[row]` for every
/// row of the screen, so a screen that grew without its flags is an
/// out-of-bounds write in release builds. Either both carry the new geometry
/// after this returns, or an error left both untouched.
///
/// ```zig
/// try resizeScreenStorage(.{ .gpa = gpa, .screen = screen, .damaged_rows = damaged, .cols = cols, .rows = rows });
/// ```
pub fn resizeScreenStorage(resize_request: ScreenResize) !void {
    const gpa = resize_request.gpa;
    const screen = resize_request.screen;
    const damaged_rows = resize_request.damaged_rows;
    const cols = resize_request.cols;
    const rows = resize_request.rows;

    const damaged = try gpa.alloc(bool, rows);
    screen.resize(cols, rows) catch |err| {
        gpa.free(damaged);
        return err;
    };
    @memset(damaged, false);
    gpa.free(damaged_rows.*);
    damaged_rows.* = damaged;
}

pub fn historyClock(io: std.Io) Clock {
    return .{
        .real_ms = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .awake_ns = @intCast(std.Io.Timestamp.now(io, .awake).toNanoseconds()),
    };
}
