//! Connecting a client to its machine's runtime, off the event loop: the
//! local runtime, started when none is running, or a remote one through its
//! SSH forward. A connection job runs this and hands the client the result.
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
        .remote => |machine| {
            var forward = try remote.establish(io, gpa, environ, machine, report);
            errdefer forward.stop(io);

            var connector = try RuntimeConnector.init(io, environ, forward.localPathZ());
            connector.report = report;
            return .{
                .channel = try remote.connectForwarded(io, &connector),
                .forward = forward,
            };
        },
    }
}
