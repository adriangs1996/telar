const std = @import("std");
const Discovery = @import("Discovery.zig");
/// The SSH session that carries one client's connection to a remote
/// runtime: `ssh … telar server bridge` over the destination's control
/// master, its standard input and output one end of a socket pair whose
/// other end the client reads and writes. No local socket file exists, so
/// two clients never share or remove each other's. Stopping it kills that
/// ssh; the remote bridge then reads the end of its input and exits, and so
/// does it when this process dies without stopping it.
const Forward = @This();

child: std.process.Child,
discovery: Discovery,

pub fn stop(self: *Forward, io: std.Io) void {
    self.child.kill(io);
}

/// Copies what ssh printed on standard error so far, up to what `writer`
/// holds, without waiting for more: after the session failed, that is the
/// reason, such as a lost connection or the remote bridge's own error.
///
/// ```zig
/// forward.reportErrors(&writer);
/// ```
pub fn reportErrors(self: *const Forward, writer: *std.Io.Writer) void {
    const stderr = self.child.stderr orelse return;
    const unused = writer.unusedCapacitySlice();
    const read = std.posix.read(stderr.handle, unused) catch return;
    writer.advance(read);
}
