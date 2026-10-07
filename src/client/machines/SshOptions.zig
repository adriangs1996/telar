//! The one way telar runs `ssh`. Batch mode, so nothing in the background
//! ever asks for a password or a host key; keepalives, so a dead link is
//! noticed; no agent forwarding; and one control master per destination in
//! telar's owner-only runtime directory, so discovery, every window's
//! bridge session, dispatch and git share one authenticated connection.
const core = @import("telar-core");
const std = @import("std");
const RuntimeConnector = @import("RuntimeConnector.zig");
const SshOptions = @This();

/// Seconds between keepalives, and keepalives missed before giving up.
pub const keepalive_interval_s = 15;
pub const keepalive_misses = 4;
/// Seconds an idle control master stays up after its last session.
pub const control_persist_s = 600;

/// Arguments every managed call passes before its own.
pub const option_count = 14;

/// Hex digits of the destination hash in a control socket name. OpenSSH adds
/// a random suffix while it binds, and Unix socket paths are short.
const control_hash_digits = 12;

// SAFETY: prepare formats the control path before setting control_len; arguments exposes only that initialized prefix.
control_storage: [std.fs.max_path_bytes]u8 = undefined,
control_len: usize = 0,

/// Places the destination's control socket in telar's runtime
/// directory, creating the directory owner-only when it is missing.
///
/// ```zig
/// var options = try SshOptions.prepare(io, environ, "dev@box");
/// ```
pub fn prepare(io: std.Io, environ: std.process.Environ, destination: []const u8) !SshOptions {
    try core.ssh_destination.validate(destination);

    const connector = try RuntimeConnector.init(io, environ, null);
    try connector.prepareServerDirectory();
    const directory = std.fs.path.dirname(connector.endpointPath()) orelse return error.InvalidRuntimeDirectory;

    var options: SshOptions = .{};
    const written = try std.fmt.bufPrint(&options.control_storage, "ControlPath={s}/ssh-{x:0>12}", .{
        directory,
        core.ssh_destination.hash(destination) >> (@bitSizeOf(u64) - control_hash_digits * 4),
    });
    options.control_len = written.len;
    return options;
}

/// The options as argv elements, borrowed from `self`.
///
/// ```zig
/// const managed = options.arguments();
/// ```
pub fn arguments(self: *const SshOptions) [option_count][]const u8 {
    return .{
        "-o", "BatchMode=yes",
        "-o", std.fmt.comptimePrint("ServerAliveInterval={d}", .{keepalive_interval_s}),
        "-o", std.fmt.comptimePrint("ServerAliveCountMax={d}", .{keepalive_misses}),
        "-o", "ForwardAgent=no",
        "-o", "ControlMaster=auto",
        "-o", std.fmt.comptimePrint("ControlPersist={d}", .{control_persist_s}),
        "-o", self.control_storage[0..self.control_len],
    };
}

/// The options as one `GIT_SSH_COMMAND`, so Git's pushes and fetches join
/// the same control master. Git hands the value to `sh`, so every word is
/// single-quoted, and a word that holds a quote is refused.
///
/// ```zig
/// const command = try options.gitCommand(&buffer);
/// try map.put("GIT_SSH_COMMAND", command);
/// ```
pub fn gitCommand(self: *const SshOptions, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.writeAll("ssh") catch return error.SshCommandTooLong;
    for (self.arguments()) |word| {
        if (std.mem.indexOfScalar(u8, word, '\'') != null) {
            return error.UnquotableSshOption;
        }

        writer.print(" '{s}'", .{word}) catch return error.SshCommandTooLong;
    }

    return writer.buffered();
}
