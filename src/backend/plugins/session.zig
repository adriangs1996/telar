//! One long-lived tap worker child and its bounded framed dialogue.

const std = @import("std");
const effects = @import("effects.zig");
const protocol = @import("protocol.zig");

const Io = std.Io;

pub const Session = struct {
    gpa: std.mem.Allocator,
    child: std.process.Child,
    reader_storage: Io.File.MultiReader.Buffer(1) = undefined,
    reader: Io.File.MultiReader = undefined,
    stderr_future: ?Io.Future(anyerror!void) = null,
    stderr_bytes: [4096]u8 = undefined,
    stderr_len: usize = 0,
    timeout_ms: u32,

    /// Starts one isolated `tap-worker` with empty environment and root cwd.
    ///
    /// ```zig
    /// const session = try Session.open(io, gpa, entry, 200);
    /// ```
    pub fn open(io: Io, gpa: std.mem.Allocator, entry: []const u8, timeout_ms: u32) !*Session {
        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const executable = executable_buffer[0..try std.process.executablePath(io, &executable_buffer)];
        const argv = [_][]const u8{ executable, "tap-worker", entry };
        var empty_environment = std.process.Environ.Map.init(gpa);
        defer empty_environment.deinit();
        session.* = .{
            .gpa = gpa,
            .child = try std.process.spawn(io, .{
                .argv = &argv,
                .cwd = .{ .path = "/" },
                .environ_map = &empty_environment,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
            }),
            .timeout_ms = timeout_ms,
        };
        errdefer session.child.kill(io);
        session.reader.init(gpa, io, session.reader_storage.toStreams(), &.{session.child.stdout.?});
        errdefer session.reader.deinit();
        session.stderr_future = try io.concurrent(drainStderr, .{ session, io });
        return session;
    }

    /// Kills the worker and releases its bounded stdout reader.
    ///
    /// ```zig
    /// session.close(io);
    /// ```
    pub fn close(session: *Session, io: Io) void {
        session.child.kill(io);
        if (session.stderr_future) |*future| {
            _ = future.await(io) catch {};
        }
        if (session.stderr_len != 0) {
            std.log.warn("tap worker stderr: {s}", .{session.stderr_bytes[0..session.stderr_len]});
        }
        session.reader.deinit();
        session.gpa.destroy(session);
    }

    fn drainStderr(session: *Session, io: Io) anyerror!void {
        const stderr = session.child.stderr orelse return;
        var buffer: [1024]u8 = undefined;
        while (true) {
            const count = stderr.readStreaming(io, &.{&buffer}) catch return;
            if (count == 0) return;
            const keep = @min(count, session.stderr_bytes.len - session.stderr_len);
            if (keep != 0) {
                @memcpy(session.stderr_bytes[session.stderr_len..][0..keep], buffer[0..keep]);
                session.stderr_len += keep;
            }
        }
    }

    /// Sends one exchange and returns a heap-owned effect result.
    ///
    /// ```zig
    /// const result = try session.exchange(io, spec, request);
    /// ```
    pub fn exchange(session: *Session, io: Io, spec: Spec, request: Request) !*effects.Result {
        var prefix: [protocol.prefix_bytes]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(request.bytes.len), .little);
        const stdin = session.child.stdin orelse return error.WorkerClosed;
        stdin.writeStreamingAll(io, &prefix) catch return error.WorkerWriteFailed;
        stdin.writeStreamingAll(io, request.bytes) catch return error.WorkerWriteFailed;
        const timeout: Io.Timeout = .{ .deadline = .fromNow(io, .{
            .clock = .awake,
            .raw = .fromMilliseconds(session.timeout_ms),
        }) };
        try session.readExact(&prefix, timeout);
        const response_len = std.mem.readInt(u32, &prefix, .little);
        if (response_len == 0 or response_len > effects.max_effect_bytes) return error.InvalidWorkerFrame;
        const storage = try session.gpa.alloc(u8, response_len);
        errdefer session.gpa.free(storage);
        try session.readExact(storage, timeout);
        if (storage[0] == 3) {
            const failure = try protocol.decodeError(storage);
            if (failure.event_id != request.event_id) return error.StaleWorkerReply;
            return error.WorkerEventFailed;
        }
        const decoded = try protocol.decodeEffects(storage);
        if (decoded.event_id != request.event_id) return error.StaleWorkerReply;
        const result = try session.gpa.create(effects.Result);
        result.* = .{
            .gpa = session.gpa,
            .package_index = spec.package_index,
            .plugin_id = spec.plugin_id,
            .digest = spec.digest,
            .generation = spec.generation,
            .event_id = decoded.event_id,
            .storage = storage,
            .batch = decoded.batch,
        };
        return result;
    }

    fn readExact(session: *Session, output: []u8, timeout: Io.Timeout) !void {
        const reader = session.reader.reader(0);
        var offset: usize = 0;
        while (offset != output.len) {
            const buffered = reader.buffered();
            const count = @min(buffered.len, output.len - offset);
            if (count != 0) {
                @memcpy(output[offset..][0..count], buffered[0..count]);
                reader.toss(count);
                offset += count;
                continue;
            }

            session.reader.fill(1, timeout) catch |err| switch (err) {
                error.Timeout => return error.WorkerTimeout,
                error.EndOfStream => return error.WorkerClosed,
                else => return error.WorkerReadFailed,
            };
        }
    }
};

pub const Spec = struct {
    package_index: u8,
    plugin_id: u64,
    digest: [32]u8,
    generation: u64,
};

pub const Request = struct {
    event_id: u64,
    bytes: []u8,
};
