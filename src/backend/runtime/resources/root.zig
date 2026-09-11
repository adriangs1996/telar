//! Physical resources acquired and owned for one runtime lifetime.

const std = @import("std");
const core = @import("telar-core");
const pty = @import("../../pty/root.zig");
const transport = @import("../../transport/root.zig");
const client_store = @import("../client/root.zig").store;
const config = @import("../config.zig");
const history_runtime = @import("history.zig");
const engine_runtime = @import("engine.zig");
const plugins_runtime = @import("plugins.zig");
const attachment = @import("../attachment/root.zig");
const proxy_runtime = @import("proxy.zig");
const telemetry = @import("../observability/root.zig").telemetry;

pub const git_probe = @import("git_probe.zig");

pub const Io = std.Io;
pub const diagnostics = core.diagnostics;

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

pub const Resources = @import("Resources.zig");

pub fn submitCapture(context: *anyopaque, exchange: *@import("../../proxy/root.zig").CaptureExchange) void {
    const service: *@import("../../plugins/root.zig").Service = @ptrCast(@alignCast(context));
    service.submit(exchange);
}

pub fn checkpoint(comptime fail_after: ?AcquisitionPhase, comptime phase: AcquisitionPhase) !void {
    if (comptime fail_after == phase) {
        return error.InjectedStartupFailure;
    }
}

pub fn initTelemetry(io: Io, endpoint: []const u8) telemetry.State {
    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "runtime-{d}", .{std.c.getpid()}) catch "runtime";
    return telemetry.State.init(io, endpoint, suffix);
}

pub fn createClientStore(gpa: std.mem.Allocator) !*client_store.Store {
    const clients = try gpa.create(client_store.Store);
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
            Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }),
        );
    }
}
