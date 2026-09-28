//! Attaching a client to the runtime on an SSH host (docs/flows/remote-attach.md).
//! Discovery asks the machine for its home, login shell, runtime socket and
//! wire schema; then one `ssh … telar server bridge` session carries the
//! client's connection on its standard input and output, which are one end
//! of a local socket pair. Both calls go through the destination's control
//! master, so every window, check, dispatch and Git transfer to a machine
//! shares one SSH connection and one authentication. The wire protocol,
//! framing and backpressure are unchanged; shared-memory graphics are
//! disabled because the runtime lives on another machine.

const core = @import("telar-core");
const localsocket = @import("localsocket");
const std = @import("std");
const Forward = @import("Forward.zig");
const RuntimeConnection = @import("RuntimeConnection.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const Discovery = @import("Discovery.zig");
const remote_discovery = @import("remote_discovery.zig");
const SshOptions = @import("SshOptions.zig");
const RemoteMachine = @import("RemoteMachine.zig");

/// The most SSH error output kept, in bytes.
const ssh_error_limit = 16 * 1024;

const endpoint_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(30) },
};

/// What the machine runs to discover itself. `/bin/sh` reads it the same
/// way whatever the login shell is.
const discovery_command = "/bin/sh -c 'printf \"%s\\n\" \"$HOME\" \"${SHELL:-/bin/sh}\"; exec telar server endpoint'";

/// What the machine runs to carry one connection; every shell reads it.
const bridge_command = "exec telar server bridge";

/// Failures of an `ssh` call, told apart by whether retrying can fix them
/// (`machine_connection.permanent`).
pub const SshFailure = error{
    SshHostKeyRejected,
    SshAuthenticationFailed,
    RemoteTelarMissing,
    RemoteRuntimeIncompatible,
    RemoteEndpointUnavailable,
};

/// Exit statuses that name a cause: OpenSSH exits 255 when it fails itself
/// (ssh(1), EXIT STATUS), and a POSIX shell exits 127 for a command it
/// cannot find and 126 for one it cannot run (sh(1p), EXIT STATUS).
const ExitStatus = enum(u8) {
    command_not_executable = 126,
    command_not_found = 127,
    ssh_failed = 255,
    _,
};

/// What OpenSSH prints when the host key is unknown or changed and strict
/// checking is on, as batch mode makes it (sshconnect.c).
const host_key_texts = [_][]const u8{
    "Host key verification failed",
    "REMOTE HOST IDENTIFICATION HAS CHANGED",
};

/// What OpenSSH prints when the server accepts none of the offered
/// credentials (sshconnect2.c) or stops after too many (sshd).
const authentication_texts = [_][]const u8{
    "Permission denied (",
    "Too many authentication failures",
};

/// What `telar server endpoint` prints when the runtime it reaches speaks
/// another schema (`RuntimeConnector.finishHandshake` without a report).
const runtime_mismatch_text = "telar protocol mismatch";

/// Discovers the machine, refuses one whose `telar` speaks another schema,
/// then starts the bridge session and completes the handshake through it.
/// What went wrong goes to `report`: SSH's or the bridge's error output, or
/// the runtime's refusal.
///
/// ```zig
/// var connection = try remote.connect(io, gpa, environ, .{ .destination = "dev@build-box" }, &report);
/// defer connection.close(io);
/// ```
pub fn connect(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, machine: RemoteMachine, report: *std.Io.Writer) !RuntimeConnection {
    try core.ssh_destination.validate(machine.destination);
    const discovery = try discover(io, gpa, environ, machine.destination, report);
    if (!discovery.compatible()) {
        report.print("that machine's telar speaks wire schema {s}; this one speaks {s}. Install the same telar build on both machines", .{ &discovery.schema, &core.schema_id }) catch {};
        return error.RemoteTelarIncompatible;
    }

    const ends = try localsocket.pair();
    var local = ends[0];
    errdefer local.deinit(io);
    var bridge = ends[1];
    defer bridge.deinit(io);

    const options = try SshOptions.prepare(io, environ, machine.destination);
    const managed = options.arguments();
    const bridge_file: std.Io.File = .{ .handle = bridge.stream.socket.handle, .flags = .{ .nonblocking = false } };
    var forward: Forward = .{
        .child = try std.process.spawn(io, .{
            .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", machine.destination, bridge_command }),
            .stdin = .{ .file = bridge_file },
            .stdout = .{ .file = bridge_file },
            .stderr = .pipe,
        }),
        .discovery = discovery,
    };
    errdefer forward.stop(io);

    // The error output is read only after the session failed, and never
    // waits for more.
    try setNonblocking(forward.child.stderr.?.handle);

    const channel = RuntimeConnector.negotiate(io, local, report) catch |err| {
        forward.reportErrors(report);
        return err;
    };

    return .{
        .channel = channel,
        .forward = forward,
    };
}

/// Asks the machine for its home, login shell, runtime socket and wire
/// schema over the managed SSH connection, starting its runtime when none
/// is running. It never installs anything. What went wrong goes to
/// `report` when given, and to standard error otherwise; the error says
/// whether retrying can fix it.
///
/// ```zig
/// const found = try remote.discover(io, gpa, environ, "dev@box", null);
/// ```
pub fn discover(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, destination: []const u8, report: ?*std.Io.Writer) !Discovery {
    const options = try SshOptions.prepare(io, environ, destination);
    const managed = options.arguments();
    const result = std.process.run(gpa, io, .{
        .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", destination, discovery_command }),
        .stdout_limit = .limited(Discovery.max_output_bytes),
        .stderr_limit = .limited(ssh_error_limit),
        .timeout = endpoint_timeout,
    }) catch return error.RemoteEndpointUnavailable;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        const failure = sshFailure(result.term, result.stderr);
        if (report) |writer| {
            writeFailure(writer, failure, result.stderr);
        } else {
            std.debug.print("telar: `ssh {s} telar server endpoint` failed:\n{s}", .{ destination, result.stderr });
        }

        return failure;
    }

    return Discovery.parse(result.stdout) catch |err| {
        const unreadable = "`telar server endpoint` there printed something this telar cannot read; install the same telar build on both machines and keep shell startup files quiet";
        if (report) |writer| {
            writer.writeAll(unreadable) catch {};
        } else {
            std.debug.print("telar: {s}\n", .{unreadable});
        }

        return err;
    };
}

/// Why an `ssh` call that did not succeed failed, from its exit status and
/// error output. A refused host key, a refused login, a `telar` the remote
/// shell cannot run and a remote runtime of another build stay until
/// someone fixes them; anything else, such as a refused or timed-out
/// connection, may pass.
///
/// ```zig
/// return remote.sshFailure(result.term, result.stderr);
/// ```
pub fn sshFailure(term: std.process.Child.Term, stderr: []const u8) SshFailure {
    const status = switch (term) {
        .exited => |code| code,
        else => return error.RemoteEndpointUnavailable,
    };

    if (std.mem.indexOf(u8, stderr, runtime_mismatch_text) != null) {
        return error.RemoteRuntimeIncompatible;
    }

    switch (@as(ExitStatus, @enumFromInt(status))) {
        .command_not_found, .command_not_executable => return error.RemoteTelarMissing,
        .ssh_failed => {
            if (mentionsAny(stderr, &host_key_texts)) {
                return error.SshHostKeyRejected;
            }

            if (mentionsAny(stderr, &authentication_texts)) {
                return error.SshAuthenticationFailed;
            }

            return error.RemoteEndpointUnavailable;
        },
        _ => return error.RemoteEndpointUnavailable,
    }
}

fn mentionsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) != null) {
            return true;
        }
    }

    return false;
}

// Names a permanent cause before SSH's own words, which are clear for host
// keys and logins but not for a missing command or an old runtime.
fn writeFailure(writer: *std.Io.Writer, failure: SshFailure, stderr: []const u8) void {
    const cause: []const u8 = switch (failure) {
        error.RemoteTelarMissing => "telar is not on the PATH of non-interactive SSH sessions there: ",
        error.RemoteRuntimeIncompatible => "the runtime there is another telar build; run `telar server stop` there: ",
        else => "",
    };
    writer.writeAll(cause) catch {};
    writer.writeAll(stderr) catch {};
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL);
    if (flags < 0) {
        return error.Unexpected;
    }

    const nonblocking: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    if (std.c.fcntl(fd, std.posix.F.SETFL, flags | nonblocking) < 0) {
        return error.Unexpected;
    }
}

test "ssh failures that retrying cannot fix are told apart from passing ones" {
    const cases = [_]struct { std.process.Child.Term, []const u8, SshFailure }{
        .{ .{ .exited = 255 }, "No ED25519 host key is known for [127.0.0.1]:2222 and you have requested strict checking.\r\nHost key verification failed.\r\n", error.SshHostKeyRejected },
        .{ .{ .exited = 255 }, "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\n", error.SshHostKeyRejected },
        .{ .{ .exited = 255 }, "telar@127.0.0.1: Permission denied (publickey).\r\n", error.SshAuthenticationFailed },
        .{ .{ .exited = 127 }, "sh: 1: exec: telar: not found\n", error.RemoteTelarMissing },
        .{ .{ .exited = 126 }, "sh: 1: exec: telar: Permission denied\n", error.RemoteTelarMissing },
        .{ .{ .exited = 1 }, "telar protocol mismatch: runtime expects schema v0000000\n", error.RemoteRuntimeIncompatible },
        .{ .{ .exited = 255 }, "ssh: connect to host box port 22: Connection refused\r\n", error.RemoteEndpointUnavailable },
        .{ .{ .exited = 255 }, "ssh: Could not resolve hostname box: nodename nor servname provided\r\n", error.RemoteEndpointUnavailable },
        .{ .{ .exited = 1 }, "error: RuntimeUnavailable\n", error.RemoteEndpointUnavailable },
        .{ .{ .signal = .KILL }, "", error.RemoteEndpointUnavailable },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case[2], sshFailure(case[0], case[1]));
    }
}

test {
    _ = remote_discovery;
}
