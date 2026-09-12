//! Temporary native-loop bridge. Step 9 replaces this driver with the shared
//! inbox/outbox execution model. Only the window thread consumes completions.
const std = @import("std");
const client = @import("telar-client");
const native = @import("native/native.zig");
const Driver = @This();

io: std.Io,
fds: [2]c_int,
reader: ?std.Io.Future(void) = null,
writer: ?std.Io.Future(void) = null,
read_ready: std.atomic.Value(bool) = .init(false),
write_ready: std.atomic.Value(bool) = .init(false),
read_result: anyerror![]u8 = error.NotStarted,
write_result: anyerror!void = error.NotStarted,

pub fn init(io: std.Io) !Driver {
    var fds: [2]c_int = undefined;
    if (native.telar_gui_pipe(&fds) != 0) {
        return error.WakePipeFailed;
    }

    return .{ .io = io, .fds = fds };
}

/// Joins I/O before the connection or its borrowed buffers can be freed.
/// Example: `driver.deinit();`
pub fn deinit(driver: *Driver) void {
    if (driver.reader) |*future| {
        future.cancel(driver.io);
    }

    if (driver.writer) |*future| {
        future.cancel(driver.io);
    }

    native.telar_gui_close_pipe(&driver.fds);
}

pub fn startRead(driver: *Driver, state: *client.RuntimeTransportState) !void {
    std.debug.assert(driver.reader == null);
    driver.reader = try std.Io.concurrent(driver.io, read, .{ driver, state });
}

pub fn startSend(driver: *Driver, request: Send) !void {
    std.debug.assert(driver.writer == null);
    driver.writer = try std.Io.concurrent(driver.io, send, .{ driver, request });
}

pub const Send = @import("RuntimeSend.zig");

fn read(driver: *Driver, state: *client.RuntimeTransportState) void {
    driver.read_result = state.read(driver.io);
    driver.read_ready.store(true, .release);
    native.telar_gui_wake(driver.fds[1]);
}

fn send(driver: *Driver, request: Send) void {
    driver.write_result = request.state.send(driver.io, request.bytes);
    driver.write_ready.store(true, .release);
    native.telar_gui_wake(driver.fds[1]);
}

/// Drains at most one completion per direction, preserving the read borrow
/// until dispatch finishes. Example: `const status = try driver.drain(app);`
pub fn drain(driver: *Driver, app: *client.AttachedClient) !?u8 {
    if (driver.write_ready.swap(false, .acquire)) {
        driver.writer.?.await(driver.io);
        driver.writer = null;
        try client.runtime_io.handleSent(app, driver.write_result);
    }

    if (driver.read_ready.swap(false, .acquire)) {
        driver.reader.?.await(driver.io);
        driver.reader = null;
        return try client.runtime_io.handleRead(app, driver.read_result);
    }

    return null;
}
