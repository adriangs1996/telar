//! Rendering, JSON and subprocess I/O stay on one bounded GUI observation task.
const std = @import("std");
const Job = @import("Job.zig");
const Image = @import("Image.zig");
const Task = @import("ProcessTask.zig");
const protocol = @import("protocol.zig");
const engine = @import("diagram_renderer_options");

/// Owns the helper until exit or cancellation, then returns bounded pixels.
/// Example: `const image = try worker.render(io, allocator, &job);`
pub fn render(io: std.Io, allocator: std.mem.Allocator, job: *const Job) !Image {
    if (job.kind == .local_image) {
        return @import("../image/attachment.zig").load(io, allocator, job.text());
    }

    var task: Task = .{ .io = io, .allocator = allocator, .job = job };
    return renderTask(&task);
}

/// Runs one owned task under a deadline, including writing, reading and child exit.
/// Example: `const image = try worker.renderTask(&task);`
pub fn renderTask(task: *Task) !Image {
    const io = task.io;
    const allocator = task.allocator;
    var adopted = false;
    defer if (!adopted) {
        if (task.result) |result| {
            var image = result;
            image.deinit(allocator);
        } else |_| {}
    };
    const Result = union(enum) { finished: void, timeout: anyerror!void };
    var results: [2]Result = undefined;
    var select: std.Io.Select(Result) = .init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.finished, execute, .{task});
    try select.concurrent(.timeout, deadline, .{task});
    switch (try select.await()) {
        .finished => {
            const image = try task.result;
            adopted = true;
            return image;
        },
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn deadline(task: *Task) !void {
    try task.io.sleep(.fromMilliseconds(task.timeout_ms), .awake);
}

fn execute(task: *Task) void {
    task.result = exchange(task);
}

fn exchange(task: *Task) !Image {
    const allocator = task.allocator;
    const io = task.io;
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const directory = std.fs.path.dirname(executable) orelse return error.RendererUnavailable;
    const helper = try std.fs.path.join(allocator, &.{ directory, "telar-diagram-renderer" });
    defer allocator.free(helper);
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    var child = std.process.spawn(io, .{ .argv = &.{task.executable orelse helper}, .environ_map = &environment, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore }) catch |err| retry: {
        if (task.executable != null or err != error.FileNotFound or std.mem.indexOf(u8, executable, "/.zig-cache/") == null) {
            return error.RendererUnavailable;
        }
        break :retry std.process.spawn(io, .{ .argv = &.{engine.helper_path}, .environ_map = &environment, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore }) catch return error.RendererUnavailable;
    };
    defer killAndReap(&child, io);

    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    var background: [7]u8 = undefined;
    var foreground: [7]u8 = undefined;
    var accent: [7]u8 = undefined;
    try std.json.Stringify.value(.{ .source = task.job.text(), .scale = task.job.scale, .bg = hex(task.job.theme.bg, &background), .fg = hex(task.job.theme.fg, &foreground), .accent = hex(task.job.theme.accent, &accent) }, .{}, &input.writer);
    try child.stdin.?.writeStreamingAll(io, input.written());
    child.stdin.?.close(io);
    child.stdin = null;

    const output = readOutput(task, child.stdout.?);
    var adopted = false;
    defer if (!adopted) {
        if (output) |value| {
            var image = value;
            image.deinit(allocator);
        } else |_| {}
    };
    if (output) |_| {} else |err| {
        if (err != error.EndOfStream) {
            return err;
        }
    }
    const child_id = child.id;
    const term = child.wait(io) catch |err| {
        // Zig 0.16 closes pipes and clears the PID even when wait is canceled.
        // A failed wait has not reaped our child; preserve its sole cleanup owner.
        child.id = child_id;
        return err;
    };
    switch (term) {
        .exited => |code| switch (code) {
            0 => {},
            3 => return error.UnsupportedDiagram,
            4 => return error.DiagramLimit,
            else => return error.InvalidDiagram,
        },
        else => return error.InvalidDiagram,
    }
    const image = try output;
    adopted = true;
    return image;
}

fn killAndReap(child: *std.process.Child, io: std.Io) void {
    if (child.id) |pid| {
        // Child.kill uses TERM on POSIX. Enforce the deadline even if a helper
        // ignores TERM, then let Child.kill perform the uncancelable reap.
        std.posix.kill(pid, .KILL) catch {};
    }

    child.kill(io);
}

fn readOutput(task: *Task, file: std.Io.File) !Image {
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(task.io, &buffer);
    var header: [protocol.header_bytes]u8 = undefined;
    try reader.interface.readSliceAll(&header);
    const length = try protocol.pixelBytes(&header);
    const bytes = try task.allocator.alloc(u8, protocol.header_bytes + length);
    errdefer task.allocator.free(bytes);
    @memcpy(bytes[0..protocol.header_bytes], &header);
    try reader.interface.readSliceAll(bytes[protocol.header_bytes..]);
    if (reader.interface.takeByte()) |_| {
        return error.DiagramLimit;
    } else |err| {
        if (err != error.EndOfStream) {
            return err;
        }
    }
    return protocol.decode(bytes);
}

fn hex(rgb: [3]u8, buffer: *[7]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }) catch unreachable;
}

test {
    _ = @import("worker_test.zig");
}
