//! Physical resources acquired and owned for one runtime lifetime.

const Exchange = @import("../../proxy/capture/Exchange.zig");
const ServiceType = @import("../../plugins/Service.zig");
const std = @import("std");
const StateType = @import("../observability/State.zig");
const StoreType = @import("../client/Store.zig");
const Resources = @import("Resources.zig");

pub const AcquisitionPhase = enum {
    child_environment,
    proxy,
    listener,
    telemetry,
    clients,
    history,
    plugins,
    engine,
};

pub fn submitCapture(context: *anyopaque, exchange: *Exchange) void {
    const service: *ServiceType = @ptrCast(@alignCast(context));
    service.submit(exchange);
}

pub fn checkpoint(comptime fail_after: ?AcquisitionPhase, comptime phase: AcquisitionPhase) !void {
    if (comptime fail_after == phase) {
        return error.InjectedStartupFailure;
    }
}

pub fn initTelemetry(io: std.Io, endpoint: []const u8) StateType {
    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "runtime-{d}", .{std.c.getpid()}) catch "runtime";
    return StateType.init(io, endpoint, suffix);
}

pub fn createClientStore(gpa: std.mem.Allocator) !*StoreType {
    const clients = try gpa.create(StoreType);
    clients.* = .{};
    return clients;
}

test "every resource acquisition checkpoint rolls back" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(io, &directory_buffer);

    inline for (std.enums.values(AcquisitionPhase), 0..) |phase, index| {
        var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/resource-{d}.sock", .{ directory_buffer[0..directory_len], index });
        var resources: Resources = undefined;

        try std.testing.expectError(error.InjectedStartupFailure, resources.acquire(.{
            .dependencies = .{ .io = io, .allocator = std.testing.allocator },
            .options = .{ .endpoint = endpoint, .environment = std.testing.environ },
        }, phase));

        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
        );
    }
}
