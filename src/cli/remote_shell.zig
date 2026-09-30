//! Running scripts on a machine over its managed SSH connection. The login
//! shell there may be sh, bash, zsh or fish, and each quotes differently, so
//! it only ever reads one constant command, `exec /bin/sh -s`; the script
//! travels on standard input and `/bin/sh` reads it. Values the script needs
//! are written at its top as `/bin/sh` single-quoted assignments, which no
//! login shell parses.
const client = @import("telar-client");
const std = @import("std");
const childoutput = @import("childoutput");
const ScriptOutput = @import("ScriptOutput.zig");
const SshOptions = client.SshOptions;
const RuntimeConnector = client.RuntimeConnector;
const ChildOutput = childoutput.ChildOutput;

/// What the login shell there runs; `/bin/sh` reads the script from stdin.
pub const script_command = "exec /bin/sh -s";

/// Newest diagnostic bytes kept: the last lines say why a script stopped.
const kept_stderr_bytes = 64 * 1024;

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

/// Runs `script` with `/bin/sh` on the machine and collects the newest
/// bytes it printed; no amount of output fails it, and a caller that parses
/// standard output reads it through `ScriptOutput.wholeStdout`. The script goes through an owner-only file beside the control sockets,
/// removed when the call returns.
///
/// ```zig
/// const output = try remote_shell.runScript(process_init, "dev@box", script, 60);
/// defer output.deinit(process_init.gpa);
/// ```
pub fn runScript(init: std.process.Init, destination: []const u8, script: []const u8, timeout_s: u32) !ScriptOutput {
    return runWithBytes(init, destination, script_command, script, timeout_s);
}

/// Runs `remote_command` on the machine with `bytes` as its standard input,
/// through the same owner-only file as `runScript`.
///
/// ```zig
/// const output = try remote_shell.runWithBytes(process_init, "dev@box", "/opt/telar machine receive-config", stream, 120);
/// ```
pub fn runWithBytes(init: std.process.Init, destination: []const u8, remote_command: []const u8, bytes: []const u8, timeout_s: u32) !ScriptOutput {
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
    try file.writePositionalAll(init.io, bytes, 0);
    return runWithInput(init, destination, remote_command, file, timeout_s);
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

    return collect(init.gpa, init.io, &child, timeout_s);
}

// The newest bytes a script printed on each stream, and how it ended.
fn collect(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child, timeout_s: u32) !ScriptOutput {
    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(timeout_s) } };
    const output = try ChildOutput.collect(gpa, io, child, .{
        .stdout = .{
            .keep_tail = ScriptOutput.kept_stdout_bytes,
        },
        .stderr = .{
            .keep_tail = kept_stderr_bytes,
        },
        .timeout = timeout,
    });
    return .{
        .term = output.term,
        .stdout = output.stdout.bytes,
        .stderr = output.stderr.bytes,
        .stdout_dropped = output.stdout.dropped,
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

test "a script that prints more than is kept still reports how it ended" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "i=0; while [ $i -lt 20000 ]; do echo \"npm warn deprecated package-$i\" >&2; i=$((i+1)); done; echo installed; echo 'last words' >&2" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    const output = try collect(std.testing.allocator, io, &child, 60);
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.succeeded());
    try std.testing.expectEqualStrings("installed\n", output.stdout);
    try std.testing.expect(output.stderr.len <= kept_stderr_bytes);
    try std.testing.expectEqualStrings("last words", output.errorLine());
}
