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
const childoutput = @import("childoutput");
const localsocket = @import("localsocket");
const std = @import("std");
const Forward = @import("Forward.zig");
const RuntimeConnection = @import("RuntimeConnection.zig");
const RuntimeConnector = @import("RuntimeConnector.zig");
const Discovery = @import("Discovery.zig");
const remote_discovery = @import("remote_discovery.zig");
const SshOptions = @import("SshOptions.zig");
const RemoteMachine = @import("RemoteMachine.zig");
const ChildOutput = childoutput.ChildOutput;

/// Newest bytes of SSH's error output kept; a long login banner before the
/// error never hides it.
const ssh_error_limit = 16 * 1024;

const endpoint_timeout: std.Io.Timeout = .{
    .duration = .{ .clock = .awake, .raw = .fromSeconds(30) },
};

/// What the machine runs to discover itself, around the program that names
/// its telar. `/bin/sh` reads it the same way whatever the login shell is.
const discovery_prefix = "/bin/sh -c 'printf \"%s\\n\" \"$HOME\" \"${SHELL:-/bin/sh}\"; exec ";
const discovery_suffix = " server endpoint'";

/// What the machine runs to carry one connection; every shell reads it.
const bridge_prefix = "exec ";
const bridge_suffix = " server bridge";

/// The longest remote command this file builds, in bytes.
const max_command_bytes = discovery_prefix.len + core.remote_telar.max_path_bytes + discovery_suffix.len;

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

/// The lines of a refused host key worth keeping: which key and why
/// ("No ED25519 host key is known for box and you have requested strict
/// checking.", "Host key for box has changed and …") and the verdict.
const host_key_verdict_texts = [_][]const u8{
    "you have requested strict checking",
    "Host key verification failed",
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
    const discovery = try discover(io, gpa, environ, machine, report);
    if (!discovery.compatible()) {
        report.print("that machine's telar speaks wire schema {s}; this one speaks {s}. Install the same telar build on both machines", .{ &discovery.schema, &core.schema_id }) catch {};
        return error.RemoteTelarIncompatible;
    }

    const options = try SshOptions.prepare(io, environ, machine.destination);
    const managed = options.arguments();
    var command_buffer: [max_command_bytes]u8 = undefined;
    const bridge_command = try remoteCommand(&command_buffer, machine.telar_path, bridge_prefix, bridge_suffix);
    return openSession(io, &(.{ "ssh", "-T" } ++ managed ++ .{ "--", machine.destination, bridge_command }), discovery, report);
}

// Runs `argv` with one end of a socket pair as its standard input and
// output and completes the handshake over the other end.
fn openSession(io: std.Io, argv: []const []const u8, discovery: Discovery, report: *std.Io.Writer) !RuntimeConnection {
    const ends = try localsocket.pair();
    var local = ends[0];
    // `negotiate` owns this end once called and closes it when it fails.
    var local_owned = true;
    errdefer if (local_owned) {
        local.deinit(io);
    };
    // This process closes its copy of the child's end as soon as the child
    // holds its own: while any copy stays open here, the local end never
    // reads the end of the stream when the child dies, and the handshake
    // waits forever. Only the descriptor closes; `SocketChannel.deinit`
    // would shut the socket down, ending the child's input and output too.
    const bridge = ends[1];
    const bridge_file: std.Io.File = .{ .handle = bridge.stream.socket.handle, .flags = .{ .nonblocking = false } };
    const spawned = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .{ .file = bridge_file },
        .stdout = .{ .file = bridge_file },
        .stderr = .pipe,
    });
    bridge.stream.close(io);

    var forward: Forward = .{
        .child = try spawned,
        .discovery = discovery,
    };
    errdefer forward.stop(io);

    // The error output is read only after the session failed, and never
    // waits for more.
    try setNonblocking(forward.child.stderr.?.handle);

    local_owned = false;
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
/// const found = try remote.discover(io, gpa, environ, .{ .destination = "dev@box" }, null);
/// ```
pub fn discover(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ, machine: RemoteMachine, report: ?*std.Io.Writer) !Discovery {
    const destination = machine.destination;
    const options = try SshOptions.prepare(io, environ, destination);
    const managed = options.arguments();
    var command_buffer: [max_command_bytes]u8 = undefined;
    const discovery_command = try remoteCommand(&command_buffer, machine.telar_path, discovery_prefix, discovery_suffix);
    var child = std.process.spawn(io, .{
        .argv = &(.{ "ssh", "-T" } ++ managed ++ .{ "--", destination, discovery_command }),
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.RemoteEndpointUnavailable;
    defer child.kill(io);

    // More than an endpoint's few lines is a startup file that prints, which
    // no retry cures.
    const result = ChildOutput.collect(gpa, io, &child, .{
        .stdout = .{ .fail_past = Discovery.max_output_bytes },
        .stderr = .{ .keep_tail = ssh_error_limit },
        .timeout = endpoint_timeout,
    }) catch |err| switch (err) {
        error.StreamTooLong => return unreadable(report),
        else => return error.RemoteEndpointUnavailable,
    };
    defer result.deinit(gpa);

    if (!result.succeeded()) {
        const failure = sshFailure(result.term, result.stderr.bytes);
        if (report) |writer| {
            writeFailure(writer, failure, result.stderr.bytes);
        } else {
            std.debug.print("telar: `ssh {s} telar server endpoint` failed:\n{s}", .{ destination, result.stderr.bytes });
        }

        return failure;
    }

    return Discovery.parse(result.stdout.bytes) catch unreadable(report);
}

// Says the endpoint's answer could not be read, and why that happens.
fn unreadable(report: ?*std.Io.Writer) error{RemoteDiscoveryUnreadable} {
    const text = "`telar server endpoint` there printed something this telar cannot read; install the same telar build on both machines and keep shell startup files quiet";
    if (report) |writer| {
        writer.writeAll(text) catch {};
    } else {
        std.debug.print("telar: {s}\n", .{text});
    }

    return error.RemoteDiscoveryUnreadable;
}

/// A remote command line that runs the machine's telar: its saved path,
/// validated so no shell reads a byte of it specially, or `telar` from the
/// PATH.
///
/// ```zig
/// const command = try remote.remoteCommand(&buffer, machine.telar_path, "exec ", " server bridge");
/// ```
pub fn remoteCommand(buffer: []u8, telar_path: ?[]const u8, prefix: []const u8, suffix: []const u8) ![]const u8 {
    if (telar_path) |path| {
        try core.remote_telar.validate(path);
    }

    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ prefix, core.remote_telar.program(telar_path), suffix }) catch error.RemoteCommandTooLong;
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
// A changed host key comes with a banner longer than the link keeps, so
// only the lines that name the key and the verdict are kept.
fn writeFailure(writer: *std.Io.Writer, failure: SshFailure, stderr: []const u8) void {
    const cause: []const u8 = switch (failure) {
        error.RemoteTelarMissing => "telar is not on the PATH of non-interactive SSH sessions there: ",
        error.RemoteRuntimeIncompatible => "the runtime there is another telar build; run `telar server stop` there: ",
        else => "",
    };
    writer.writeAll(cause) catch {};
    if (failure != error.SshHostKeyRejected) {
        writer.writeAll(stderr) catch {};
        return;
    }

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (mentionsAny(line, &host_key_verdict_texts)) {
            writer.print("{s} ", .{std.mem.trim(u8, line, " \r")}) catch {};
        }
    }
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

test "remote commands name the saved telar or the one on the PATH" {
    var buffer: [max_command_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("exec telar server bridge", try remoteCommand(&buffer, null, bridge_prefix, bridge_suffix));
    try std.testing.expectEqualStrings(
        "/bin/sh -c 'printf \"%s\\n\" \"$HOME\" \"${SHELL:-/bin/sh}\"; exec /home/dev/.local/share/telar/0.3.0/telar server endpoint'",
        try remoteCommand(&buffer, "/home/dev/.local/share/telar/0.3.0/telar", discovery_prefix, discovery_suffix),
    );
    try std.testing.expectError(error.InvalidRemoteTelarPath, remoteCommand(&buffer, "/home/dev/it's", bridge_prefix, bridge_suffix));
}

test "a bridge that dies before the handshake fails the attempt with its error output" {
    const discovery = try Discovery.parse("/home/dev\n/bin/sh\n/run/telar.sock\n" ++ core.schema_id ++ "\n");
    var buffer: [256]u8 = undefined;
    var report: std.Io.Writer = .fixed(&buffer);

    if (openSession(std.testing.io, &.{ "/bin/sh", "-c", "echo bridge ended >&2" }, discovery, &report)) |connection| {
        var opened = connection;
        opened.close(std.testing.io);
        return error.TestUnexpectedResult;
    } else |_| {}

    try std.testing.expectEqualStrings("bridge ended\n", report.buffered());
}

test "a refused host key keeps which key and the verdict, not the banner" {
    const changed =
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n" ++
        "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\n" ++
        "IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\r\n" ++
        "It is also possible that a host key has just been changed.\r\n" ++
        "Add correct host key in /home/dev/.ssh/known_hosts to get rid of this message.\r\n" ++
        "Host key for box has changed and you have requested strict checking.\r\n" ++
        "Host key verification failed.\r\n";
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writeFailure(&writer, sshFailure(.{ .exited = 255 }, changed), changed);

    try std.testing.expectEqualStrings("Host key for box has changed and you have requested strict checking. Host key verification failed. ", writer.buffered());
}

test {
    _ = remote_discovery;
}
