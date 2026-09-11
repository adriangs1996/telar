//! Measurement-only VT oracle and minimal interposition controls, not a multiplexer.
const std = @import("std");
const vt = @import("ghostty-vt");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");

const Link = @import("Link.zig");

fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) {
            if (count < 0 and std.posix.errno(count) == .INTR) {
                continue;
            }
            return error.WriteFailed;
        }
        offset += @intCast(count);
    }
}

fn readExact(fd: std.c.fd_t, bytes: []u8) !bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count == 0) {
            if (offset == 0) {
                return false;
            }
            return error.TruncatedInput;
        }
        if (count < 0) {
            if (std.posix.errno(count) == .INTR) {
                continue;
            }
            return error.ReadFailed;
        }
        offset += @intCast(count);
    }
    return true;
}

fn relay(links: [2]Link) !void {
    var polling = [2]std.c.pollfd{
        .{ .fd = links[0].input, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = links[1].input, .events = std.posix.POLL.IN, .revents = 0 },
    };
    var bytes: [16 * 1024]u8 = undefined;
    while (true) {
        const ready = std.c.poll(&polling, polling.len, -1);
        if (ready < 0) {
            if (std.posix.errno(ready) == .INTR) {
                continue;
            }
            return error.PollFailed;
        }
        for (polling, links) |item, link| {
            if (item.revents == 0) {
                continue;
            }
            const count = std.c.read(link.input, &bytes, bytes.len);
            if (count <= 0) {
                return;
            }
            try writeAll(link.output, bytes[0..@intCast(count)]);
        }
    }
}

fn oracle(init: std.process.Init, size: struct { cols: u16, rows: u16 }) !void {
    var terminal = try vt.Terminal.init(init.io, init.gpa, .{ .cols = size.cols, .rows = size.rows, .max_scrollback_bytes = 0 });
    defer terminal.deinit(init.gpa);
    var stream = vt.TerminalStream.init(.{ .allocator = init.gpa, .handler = terminal.vtHandler() });
    defer stream.deinit();
    var bytes: [64 * 1024]u8 = undefined;
    var header: [4]u8 = undefined;
    while (try readExact(0, &header)) {
        const length = std.mem.readInt(u32, &header, .little);
        if (length > bytes.len) {
            return error.FrameTooLarge;
        }
        if (!try readExact(0, bytes[0..length])) {
            return error.TruncatedInput;
        }
        stream.nextSlice(bytes[0..length]);
        var count: u32 = 0;
        const pages = &terminal.screens.active.pages;
        for (0..size.rows) |y| {
            const pin = pages.pin(.{ .active = .{ .x = 0, .y = @intCast(y) } }) orelse continue;
            for (pin.cells(.all)) |cell| {
                if (cell.hasText() and cell.codepoint() == '~') {
                    count += 1;
                }
            }
        }
        var response: [8]u8 = undefined;
        std.mem.writeInt(u32, response[0..4], count, .little);
        std.mem.writeInt(u32, response[4..8], @intFromBool(terminal.modes.get(.synchronized_output)), .little);
        try writeAll(1, &response);
    }
}

fn foregroundBatch(io: std.Io, session: *const backend.pty.Session, direct: bool) !u64 {
    const Libc = struct {
        extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;
    };
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..10000) |_| {
        const group = if (direct) query: {
            const request: c_int = switch (@import("builtin").os.tag) {
                .macos => 0x40047477,
                .linux => @intCast(std.c.T.IOCGPGRP),
                else => return error.UnsupportedPlatform,
            };
            var observed_group: std.c.pid_t = 0;
            if (std.c.ioctl(session.master, request, &observed_group) != 0) {
                return error.NoForeground;
            }

            break :query observed_group;
        } else Libc.tcgetpgrp(session.master);
        if (group != session.processId()) {
            return error.UnexpectedForeground;
        }
    }

    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds - started, 10000));
}

fn foregroundBenchmark(init: std.process.Init) !void {
    const command = try backend.pty.Command.fromArgv(&.{"/bin/cat"});
    var session = try backend.pty.Session.spawn(&command, .{ .cols = 80, .rows = 24 });
    defer session.deinit();
    var buffer: [256]u8 = undefined;
    _ = try foregroundBatch(init.io, &session, false);
    _ = try foregroundBatch(init.io, &session, true);

    for (0..40) |index| {
        var values: [2]u64 = undefined;
        for (0..2) |position| {
            const kind = (position + index) % 2;
            values[kind] = try foregroundBatch(init.io, &session, kind == 1);
        }

        try writeAll(1, try std.fmt.bufPrint(&buffer, "{{\"batch\":{d},\"operations\":10000,\"libc_ns_per_op\":{d},\"direct_ns_per_op\":{d}}}\n", .{ index, values[0], values[1] }));
    }
}

/// Example: `echo-probe screen 160 40` or `echo-probe one /bin/cat`.
/// Runs native echo controls, a VT oracle, or the foreground-query experiment.
/// Example: `echo-probe screen 160 40`.
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    if (std.mem.eql(u8, mode, "foreground")) {
        return foregroundBenchmark(init);
    }

    if (std.mem.eql(u8, mode, "screen")) {
        const cols = try std.fmt.parseInt(u16, args.next() orelse return error.MissingColumns, 10);
        const rows = try std.fmt.parseInt(u16, args.next() orelse return error.MissingRows, 10);
        if (cols == 0 or rows == 0 or cols > 512 or rows > 512) {
            return error.InvalidSize;
        }

        return oracle(init, .{ .cols = cols, .rows = rows });
    }
    if (std.mem.eql(u8, mode, "app")) {
        var tty = try frontend.platform.Tty.open();
        defer tty.deinit();
        var byte: [1]u8 = undefined;
        while (try readExact(0, &byte)) {
            try writeAll(1, if (byte[0] == 0x7f) "\x08 \x08" else &byte);
        }
        return;
    }
    const socket = if (std.mem.eql(u8, mode, "one")) @as(c_int, 0) else try std.fmt.parseInt(c_int, args.next() orelse return error.MissingSocket, 10);
    if (std.mem.eql(u8, mode, "client")) {
        var tty = try frontend.platform.Tty.open();
        defer tty.deinit();
        return relay(.{ .{ .input = 0, .output = socket }, .{ .input = socket, .output = 1 } });
    }
    if (!std.mem.eql(u8, mode, "one") and !std.mem.eql(u8, mode, "server")) {
        return error.InvalidMode;
    }
    var tty: ?frontend.platform.Tty = if (socket == 0) try frontend.platform.Tty.open() else null;
    defer if (tty) |*value| {
        value.deinit();
    };
    const shell = args.next() orelse "/bin/cat";
    const command = try backend.pty.Command.fromArgv(&.{shell.ptr});
    var session = try backend.pty.Session.spawn(&command, .{ .cols = 160, .rows = 40 });
    defer session.deinit();
    return relay(.{ .{ .input = socket, .output = session.master }, .{ .input = session.master, .output = if (socket == 0) 1 else socket } });
}
