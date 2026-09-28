//! Running scripts on a machine over its managed SSH connection. The login
//! shell there may be sh, bash, zsh or fish, and each quotes differently, so
//! it only ever reads one constant command, `exec /bin/sh -s`; the script
//! travels on standard input and `/bin/sh` reads it. Values the script needs
//! are written at its top as `/bin/sh` single-quoted assignments, which no
//! login shell parses.
const client = @import("telar-client");
const std = @import("std");
const ScriptOutput = @import("ScriptOutput.zig");
const SshOptions = client.SshOptions;
const RuntimeConnector = client.RuntimeConnector;

/// What the login shell there runs; `/bin/sh` reads the script from stdin.
pub const script_command = "exec /bin/sh -s";

/// The most a script may print on standard output and error, in bytes.
const stdout_limit = 256 * 1024;
const stderr_limit = 64 * 1024;

/// Writes `value` as one `/bin/sh` word: single-quoted, each quote closed,
/// escaped and reopened, so no byte of it is ever read as syntax.
///
/// ```zig
/// try remote_shell.quote(&writer, "it's");  // 'it'\''s'
/// ```
pub fn quote(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }

    try writer.writeByte('\'');
}

/// Writes `name='value'` and a newline, for the top of a script.
///
/// ```zig
/// try remote_shell.assign(&writer, "version", "0.3.0");
/// ```
pub fn assign(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeAll(name);
    try writer.writeByte('=');
    try quote(writer, value);
    try writer.writeByte('\n');
}

/// Runs `script` with `/bin/sh` on the machine and collects what it printed.
/// The script goes through an owner-only file beside the control sockets,
/// removed when the call returns.
///
/// ```zig
/// const output = try remote_shell.runScript(process_init, "dev@box", script, 60);
/// defer output.deinit(process_init.gpa);
/// ```
pub fn runScript(init: std.process.Init, destination: []const u8, script: []const u8, timeout_s: u32) !ScriptOutput {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scriptPath(init, &path_buffer);
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(init.io, path, .{
        .read = true,
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    defer cwd.deleteFile(init.io, path) catch {};
    defer file.close(init.io);

    // A positional write leaves the offset at 0, where the child reads.
    try file.writePositionalAll(init.io, script, 0);
    return runWithInput(init, destination, script_command, file, timeout_s);
}

/// Runs `remote_command` on the machine with `input` as its standard input,
/// as an upload does with `cat > FILE`.
///
/// ```zig
/// const output = try remote_shell.runWithInput(process_init, "dev@box", command, binary, 600);
/// ```
pub fn runWithInput(init: std.process.Init, destination: []const u8, remote_command: []const u8, input: std.Io.File, timeout_s: u32) !ScriptOutput {
    const options = try SshOptions.prepare(init.io, init.minimal.environ, destination);
    var child = try std.process.spawn(init.io, .{
        .argv = &(.{ "ssh", "-T" } ++ options.arguments() ++ .{ "--", destination, remote_command }),
        .stdin = .{ .file = input },
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(init.io);

    var streams_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var streams: std.Io.File.MultiReader = undefined;
    streams.init(init.gpa, init.io, streams_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer streams.deinit();

    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_s) } };
    while (streams.fill(64, timeout)) |_| {
        if (streams.reader(0).buffered().len > stdout_limit or streams.reader(1).buffered().len > stderr_limit) {
            return error.RemoteOutputTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }

    try streams.checkAnyError();
    const term = try child.wait(init.io);
    const stdout = try streams.toOwnedSlice(0);
    errdefer init.gpa.free(stdout);
    const stderr = try streams.toOwnedSlice(1);
    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
    };
}

// A fresh owner-only path in telar's runtime directory, where the control
// sockets already live.
fn scriptPath(init: std.process.Init, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, null);
    try connector.prepareServerDirectory();
    const directory = std.fs.path.dirname(connector.endpointPath()) orelse return error.InvalidRuntimeDirectory;

    var nonce: [8]u8 = undefined;
    try init.io.randomSecure(&nonce);
    return std.fmt.bufPrint(buffer, "{s}/setup-{s}.sh", .{
        directory,
        &std.fmt.bytesToHex(nonce, .lower),
    });
}

test "quoted words survive every byte a shell reads specially" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try assign(&writer, "value", "it's $(id) `x` \"y\" \\z");

    try std.testing.expectEqualStrings("value='it'\\''s $(id) `x` \"y\" \\z'\n", writer.buffered());
}

test "a quoted word reads back unchanged through /bin/sh" {
    const value = "it's $(echo no) `echo no` \"q\" \\n ; | & * ~ \n end";
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeAll("printf '%s' ");
    try quote(&writer, value);

    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", writer.buffered() },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualStrings(value, result.stdout);
}
