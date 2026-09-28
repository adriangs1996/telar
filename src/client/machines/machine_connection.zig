//! Connecting a client to its machine's runtime, off the event loop: the
//! local runtime, started when none is running, or a remote one through its
//! SSH bridge. A connection job runs this and hands the client the result.
const std = @import("std");
const MachineTarget = @import("MachineTarget.zig").MachineTarget;
const RuntimeConnection = @import("RuntimeConnection.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const remote = @import("remote.zig");

/// Connects and completes the handshake. What SSH or the runtime said about
/// a failure goes to `report`.
///
/// ```zig
/// const connection = try machine_connection.connect(io, gpa, environ, target, &report);
/// ```
pub fn connect(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, target: MachineTarget, report: *std.Io.Writer) !RuntimeConnection {
    switch (target) {
        .local => |selection| {
            var connector = try RuntimeConnector.init(io, environ, null);
            connector.report = report;
            return .{ .channel = try connector.connectOrStart(selection) };
        },
        .remote => |machine| return remote.connect(io, gpa, environ, machine, report),
    }
}

/// Whether a failed `connect` stays failed however often it is tried again:
/// a host key or login SSH refuses, a `telar` the remote shell cannot run
/// or cannot be read, a `telar` or runtime of another build, `--fresh`
/// beside a running runtime, or a runtime directory someone else could use.
/// Anything else may pass.
///
/// ```zig
/// link.phase = if (machine_connection.permanent(err)) .failed else .lost;
/// ```
pub fn permanent(err: anyerror) bool {
    return switch (err) {
        error.SshHostKeyRejected,
        error.SshAuthenticationFailed,
        error.RemoteTelarMissing,
        error.RemoteDiscoveryUnreadable,
        error.RemoteTelarIncompatible,
        error.RemoteRuntimeIncompatible,
        error.IncompatibleSchema,
        error.RuntimeAlreadyRunning,
        error.InvalidRuntimeDirectory,
        error.InvalidRemoteDestination,
        => true,
        else => false,
    };
}

/// Whether `telar machine setup` repairs a failed `connect`: the machine
/// has no telar a remote shell can run, or one or a runtime of another
/// build.
///
/// ```zig
/// link.setup_repairs = machine_connection.setupRepairs(err);
/// ```
pub fn setupRepairs(err: anyerror) bool {
    return switch (err) {
        error.RemoteTelarMissing,
        error.RemoteDiscoveryUnreadable,
        error.RemoteTelarIncompatible,
        error.RemoteRuntimeIncompatible,
        => true,
        else => false,
    };
}

test "only a missing telar or another build is setup's to repair" {
    try std.testing.expect(setupRepairs(error.RemoteTelarMissing));
    try std.testing.expect(setupRepairs(error.RemoteRuntimeIncompatible));
    try std.testing.expect(!setupRepairs(error.SshHostKeyRejected));
    try std.testing.expect(!setupRepairs(error.RemoteEndpointUnavailable));
}

test "only failures that retrying cannot fix are permanent" {
    try std.testing.expect(permanent(error.SshHostKeyRejected));
    try std.testing.expect(permanent(error.IncompatibleSchema));
    try std.testing.expect(!permanent(error.RemoteEndpointUnavailable));
    try std.testing.expect(!permanent(error.ConnectionRefused));
}
