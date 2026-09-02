//! Publishes shared-memory frames the way terminal-browser does, at a fixed
//! size and rate, so Telar's graphics pipeline can be measured without a
//! browser: eight rotating POSIX objects, one synchronized envelope per frame
//! on stdout, and the achieved rate on stderr when the run ends.
//!
//! ```sh
//! telar-frame-source --width 3840 --height 2160 --fps 120 --seconds 20
//! ```

const std = @import("std");

const slots = 8;

const Options = struct {
    width: u32 = 3840,
    height: u32 = 2160,
    fps: u32 = 120,
    seconds: u32 = 20,
    image_id: u32 = 1,
};

fn parse(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 == args.len) return error.MissingValue;
        const name = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, name, "--width")) {
            options.width = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--height")) {
            options.height = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--fps")) {
            options.fps = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--seconds")) {
            options.seconds = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, name, "--image-id")) {
            options.image_id = try std.fmt.parseUnsigned(u32, value, 10);
        } else {
            return error.UnknownOption;
        }
    }
    if (options.width == 0 or options.height == 0 or options.fps == 0 or options.image_id == 0)
        return error.InvalidOption;
    return options;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepUntil(deadline_ns: u64) void {
    while (true) {
        const now = nowNs();
        if (now >= deadline_ns) return;
        const remaining = deadline_ns - now;
        var ts: std.c.timespec = .{
            .sec = @intCast(remaining / std.time.ns_per_s),
            .nsec = @intCast(remaining % std.time.ns_per_s),
        };
        _ = std.c.nanosleep(&ts, &ts);
    }
}

/// Creates a fresh object under `name` holding `pixels`, exactly as
/// terminal-browser's shared transport does per frame.
fn publish(name: [:0]const u8, pixels: []const u8) !void {
    _ = std.c.shm_unlink(name);
    const fd = std.c.shm_open(
        name,
        @as(c_int, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true })),
        @as(u16, 0o600),
    );
    if (std.posix.errno(fd) != .SUCCESS) return error.SharedMemoryUnavailable;
    defer _ = std.c.close(fd);
    if (std.c.ftruncate(fd, @intCast(pixels.len)) != 0) return error.SharedMemoryUnavailable;
    const map = try std.posix.mmap(
        null,
        pixels.len,
        .{ .READ = true, .WRITE = true },
        std.c.MAP{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(map);
    @memcpy(map[0..pixels.len], pixels);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parse(args) catch {
        std.debug.print(
            "usage: telar-frame-source [--width W] [--height H] [--fps N] [--seconds S] [--image-id I]\n",
            .{},
        );
        return error.InvalidArguments;
    };

    const byte_len = @as(usize, options.width) * @as(usize, options.height) * 4;
    const pixels = try gpa.alloc(u8, byte_len);
    defer gpa.free(pixels);

    const pid: u32 = @bitCast(std.c.getpid());
    var names: [slots][64]u8 = undefined;
    var name_lens: [slots]usize = undefined;
    for (0..slots) |slot| {
        const printed = try std.fmt.bufPrintZ(&names[slot], "/tlrsrc-{x}-{d}", .{ pid, slot });
        name_lens[slot] = printed.len;
    }
    defer for (0..slots) |slot| {
        _ = std.c.shm_unlink(names[slot][0..name_lens[slot] :0]);
    };

    const stdout: std.Io.File = .stdout();
    const interval_ns = std.time.ns_per_s / options.fps;
    const started = nowNs();
    const end = started + @as(u64, options.seconds) * std.time.ns_per_s;
    var frame: u64 = 0;
    var envelope: [256]u8 = undefined;
    while (true) {
        const deadline = started + frame * interval_ns;
        if (deadline >= end) break;
        sleepUntil(deadline);

        // A visibly changing frame: every byte is written, like a real one.
        @memset(pixels, @truncate(frame * 7));
        const slot = frame % slots;
        const name: [:0]const u8 = names[slot][0..name_lens[slot] :0];
        try publish(name, pixels);

        const Encoder = std.base64.standard.Encoder;
        var encoded: [128]u8 = undefined;
        const payload = Encoder.encode(encoded[0..Encoder.calcSize(name.len)], name);
        const bytes = try std.fmt.bufPrint(
            &envelope,
            "\x1b[?2026h\x1b[H\x1b_Ga=T,f=32,s={d},v={d},t=s,i={d},p=1,C=1,q=2;{s}\x1b\\\x1b[?2026l",
            .{ options.width, options.height, options.image_id, payload },
        );
        try stdout.writeStreamingAll(init.io, bytes);
        frame += 1;
    }
    const elapsed_ns = nowNs() - started;
    const achieved = if (elapsed_ns == 0) 0 else frame * std.time.ns_per_s / elapsed_ns;
    std.debug.print(
        "telar-frame-source: {d} frames of {d} bytes in {d} ms, {d} frames/s\n",
        .{ frame, byte_len, elapsed_ns / std.time.ns_per_ms, achieved },
    );
}
