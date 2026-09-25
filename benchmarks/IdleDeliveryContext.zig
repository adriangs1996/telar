//! An idle runtime for timing the delivery flush that ends each update.
const backend = @import("telar-backend");
const std = @import("std");
const IdleDeliveryShape = @import("IdleDeliveryShape.zig");
const IdleDeliveryContext = @This();

idle: backend.IdleDelivery,
io: std.Io,
directory_buffer: [std.fs.max_path_bytes]u8,
directory: []const u8,

/// Example: `var context: IdleDeliveryContext = undefined; try context.init(io, gpa, environ, shape);`.
pub fn init(self: *IdleDeliveryContext, io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, shape: IdleDeliveryShape) !void {
    self.io = io;
    self.directory = try std.fmt.bufPrint(&self.directory_buffer, "/tmp/telar-bench-idle-{d}-{d}x{d}", .{ std.c.getpid(), shape.clients, shape.panes });
    try std.Io.Dir.cwd().createDirPath(io, self.directory);
    errdefer std.Io.Dir.cwd().deleteTree(io, self.directory) catch {};

    try self.idle.init(.{ .io = io, .allocator = gpa }, .{
        .clients = shape.clients,
        .panes = shape.panes,
        .directory = self.directory,
        .environment = environ,
        .size = shape.size,
    });
}

/// Example: `context.deinit();`.
pub fn deinit(self: *IdleDeliveryContext) void {
    self.idle.deinit();
    std.Io.Dir.cwd().deleteTree(self.io, self.directory) catch {};
}
