//! Server command grammar and validated options.

const std = @import("std");

pub const ServerMode = enum {
    foreground,
    background_launcher,
    daemonized,
};

pub const ServerAction = enum {
    run,
    stop,
    /// Ensure the runtime is running and print its socket path and wire
    /// schema. Used over SSH to discover a remote machine.
    endpoint,
    /// Relay standard input and output to the running runtime's socket.
    /// Used over SSH to carry one client's connection to a remote machine.
    bridge,
};

pub fn parseMebibytes(value: [*:0]const u8) !usize {
    const mib = try std.fmt.parseUnsigned(usize, std.mem.span(value), 10);
    return std.math.mul(usize, mib, 1024 * 1024) catch error.InvalidGraphicsLimit;
}
