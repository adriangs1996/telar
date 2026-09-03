const std = @import("std");
const vt = @import("ghostty-vt");

// Bounded capture of what one command printed, resolved to plain text.
//
// Feeding the bytes through a real terminal is the whole point. Raw output is
// mostly cursor moves and redraws: a `docker pull` is half a megabyte of bytes
// for ten lines of text, and a progress bar is the same line rewritten a
// thousand times. What lands here is what you would have *seen*, which is also
// the only form worth putting in a database and handing to an agent.
//
// This is the advantage a multiplexer has over a shell-level history tool:
// Atuin would have to redirect the stream and keep the bytes; herdr already
// owns a terminal emulator.

pub const Capture = struct {
    gpa: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    recording: bool = false,
    fed: usize = 0,
    truncated: bool = false,

    /// Past this, stop feeding and flag the capture. A runaway command must not
    /// be able to turn the tap into the bottleneck.
    pub const max_bytes: usize = 256 * 1024;

    /// Roughly a screenful of history per command; enough for a build error,
    /// far from enough for a full build log, which is the intent.
    const max_scrollback_bytes: usize = 256 * 1024;

    /// Initialises in place. The stream holds a pointer to `terminal`, so a
    /// Capture must not be copied or moved after this returns.
    pub fn init(self: *Capture, io: std.Io, gpa: std.mem.Allocator, rows: u16, cols: u16) !void {
        // A pty with no window size reports 0x0, and a terminal of zero rows
        // trips an assertion deep inside PageList. Fall back to a classic
        // 24x80 rather than crashing the proxy over a cosmetic detail.
        const safe_rows = if (rows == 0) 24 else rows;
        const safe_cols = if (cols == 0) 80 else cols;

        self.* = .{
            .gpa = gpa,
            .terminal = try .init(io, gpa, .{
                .cols = safe_cols,
                .rows = safe_rows,
                .max_scrollback_bytes = max_scrollback_bytes,
            }),
            .stream = undefined,
        };
        errdefer self.terminal.deinit(gpa);

        self.stream = .init(.{
            .handler = .init(&self.terminal),
            .allocator = gpa,
        });
    }

    pub fn deinit(self: *Capture) void {
        self.stream.deinit();
        self.terminal.deinit(self.gpa);
    }

    /// OSC 133;C — start recording a fresh command.
    pub fn begin(self: *Capture) void {
        // A hard reset costs less than reasoning about leftover state from the
        // previous command's screen.
        self.terminal.fullReset();
        self.fed = 0;
        self.truncated = false;
        self.recording = true;
    }

    /// Feeds output bytes. A no-op unless a command is being recorded, so the
    /// caller can hand it every chunk without checking.
    pub fn feed(self: *Capture, bytes: []const u8) void {
        if (!self.recording or bytes.len == 0) {
            return;
        }

        if (self.fed >= max_bytes) {
            self.truncated = true;
            return;
        }
        const room = max_bytes - self.fed;
        const slice = if (bytes.len <= room) bytes else blk: {
            self.truncated = true;
            break :blk bytes[0..room];
        };

        self.stream.nextSlice(slice);
        self.fed += slice.len;
    }

    pub const Result = struct {
        text: []const u8,
        truncated: bool,
    };

    /// OSC 133;D — resolve the capture. The caller owns `text` and must free it
    /// with the same allocator. Null when nothing was recorded.
    pub fn finish(self: *Capture) ?Result {
        if (!self.recording) {
            return null;
        }
        self.recording = false;

        const raw = self.terminal.screens.active.dumpStringAlloc(
            self.gpa,
            .{ .screen = .{} },
        ) catch return null;

        // The dump pads to the full screen height, so most captures end in a
        // wall of blank lines. Hand back only the part that has content.
        const trimmed = std.mem.trimEnd(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            self.gpa.free(raw);
            return null;
        }
        if (trimmed.len < raw.len) {
            const shrunk = self.gpa.realloc(raw, trimmed.len) catch {
                return .{ .text = raw[0..trimmed.len], .truncated = self.truncated };
            };
            return .{ .text = shrunk, .truncated = self.truncated };
        }
        return .{ .text = raw, .truncated = self.truncated };
    }
};
