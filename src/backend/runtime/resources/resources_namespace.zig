//! Physical resources acquired and owned for one runtime lifetime.

const std = @import("std");
const localsocket = @import("localsocket");
const SocketDirectory = localsocket.SocketDirectory;
const core = @import("telar-core");
const State = @import("../observability/State.zig");
const Resources = @import("Resources.zig");

pub const AcquisitionPhase = enum {
    child_environment,
    proxy,
    listener,
    telemetry,
    history,
    plugins,
    engine,
};

pub fn checkpoint(comptime fail_after: ?AcquisitionPhase, comptime phase: AcquisitionPhase) !void {
    if (comptime fail_after == phase) {
        return error.InjectedStartupFailure;
    }
}

pub fn initTelemetry(io: std.Io, endpoint: []const u8) State {
    core.Sink.removeOrphans(io, endpoint);
    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "runtime-{d}", .{std.c.getpid()}) catch "runtime";
    return State.init(io, endpoint, suffix);
}

test "every resource acquisition checkpoint rolls back" {
    const io = std.testing.io;
    var temp = try SocketDirectory.create(io);
    defer temp.cleanup(io);

    inline for (std.enums.values(AcquisitionPhase), 0..) |phase, index| {
        var endpoint_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{s}/resource-{d}.sock", .{ temp.path(), index });
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
