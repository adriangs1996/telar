//! The one way telar runs `ssh`. Batch mode, so nothing in the background
//! ever asks for a password or a host key; keepalives, so a dead link is
//! noticed; no agent forwarding; and one control master per destination in
//! telar's owner-only runtime directory, so discovery, forwards, dispatch
//! and git share one authenticated connection.
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

/// Options for a socket forward. A forward never joins the control master:
/// a forward a master owns outlives the `ssh` that asked for it, so
/// stopping that process would leave the socket behind. It fails at once
/// when the forward cannot be set up and replaces a stale socket file.
pub const forward_arguments = [_][]const u8{
    "-o", "BatchMode=yes",
    "-o", std.fmt.comptimePrint("ServerAliveInterval={d}", .{keepalive_interval_s}),
    "-o", std.fmt.comptimePrint("ServerAliveCountMax={d}", .{keepalive_misses}),
    "-o", "ForwardAgent=no",
    "-o", "ControlPath=none",
    "-o", "ExitOnForwardFailure=yes",
    "-o", "StreamLocalBindUnlink=yes",
};

/// Hex digits of the destination hash in a control socket name. OpenSSH adds
/// a random suffix while it binds, and Unix socket paths are short.
const control_hash_digits = 12;

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

test "managed options keep ssh quiet, alive and shared" {
    var options: SshOptions = .{};
    const control = "ControlPath=/tmp/telar-501/ssh-0123456789ab";
    @memcpy(options.control_storage[0..control.len], control);
    options.control_len = control.len;

    const managed = options.arguments();
    try std.testing.expectEqualStrings("BatchMode=yes", managed[1]);
    try std.testing.expectEqualStrings("ServerAliveInterval=15", managed[3]);
    try std.testing.expectEqualStrings("ForwardAgent=no", managed[7]);
    try std.testing.expectEqualStrings(control, managed[13]);
}

test "the git command quotes every managed option for the shell" {
    var options: SshOptions = .{};
    const control = "ControlPath=/tmp/telar 501/ssh-0123456789ab";
    @memcpy(options.control_storage[0..control.len], control);
    options.control_len = control.len;

    var buffer: [512]u8 = undefined;
    const command = try options.gitCommand(&buffer);
    try std.testing.expect(std.mem.startsWith(u8, command, "ssh '-o' 'BatchMode=yes'"));
    try std.testing.expect(std.mem.endsWith(u8, command, " '-o' 'ControlPath=/tmp/telar 501/ssh-0123456789ab'"));

    const quoted = "ControlPath=/tmp/it's";
    @memcpy(options.control_storage[0..quoted.len], quoted);
    options.control_len = quoted.len;
    try std.testing.expectError(error.UnquotableSshOption, options.gitCommand(&buffer));
}
