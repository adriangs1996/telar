//! `telar-headless`: the shared client with no window, for tests and tools
//! (docs/flows/headless-client.md). It launches like `telar gui`, with the
//! headless flags first:
//!
//! ```sh
//! telar-headless --size 120x40 --trace trace.json --no-config -- cat
//! ```
const pty = @import("pty");
const core = @import("telar-core");
const std = @import("std");
const build_options = @import("build_options");
const headless = @import("telar-headless");
const client = @import("telar-client");
const RunOptions = @import("cli/arguments/RunOptions.zig");
const ClientLaunch = @import("cli/ClientLaunch.zig");

// Root-level opt-in contracts read by core through @hasDecl, as in the
// `telar` binary, so echo traces cover this client too.
pub const telar_diagnostics = build_options.diagnostics;
pub const telar_profile_counts = build_options.profile_counts;
pub const telar_profile_timing = build_options.profile_timing;
pub var profile_store: if (core.profiling.active) core.ProfileStore else void = if (core.profiling.active) .{} else {};
pub const telar_echo_trace = build_options.echo_trace;
pub const telar_echo_trace_cpu = build_options.echo_trace_cpu;
pub var echo_recorder: if (build_options.echo_trace) core.Recorder else void = if (build_options.echo_trace) .{} else {};

/// Exit status of a launch that failed before the client ran.
const failure: u8 = 2;

pub fn main(init: std.process.Init) !void {
    var storage: [pty.command_support.max_args][*:0]const u8 = undefined;
    const args = try collectArgs(init, &storage);
    const status = launch(init, args) catch |err| {
        std.debug.print("telar-headless: {s}\n", .{@errorName(err)});
        std.process.exit(failure);
    };

    dumpEchoTrace(init);
    std.process.exit(status);
}

fn launch(init: std.process.Init, args: []const [*:0]const u8) !u8 {
    const headless_options = try headless.HeadlessOptions.parse(args);
    const options = try RunOptions.parse(args[headless_options.consumed..], init.minimal.environ);
    if (options.machine != null) {
        return error.MachineNeedsWindow;
    }

    const connector = try client.RuntimeConnector.init(init.io, init.minimal.environ, null);
    try connector.prepareServerDirectory();

    var prepared: ClientLaunch = undefined;
    try prepared.prepare(.{
        .process = init,
        .options = &options,
        .endpoint = connector.endpointPath(),
    });
    defer prepared.deinit();

    // This binary has no runtime or plugin worker; the `telar` beside it
    // starts them.
    var telar_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const telar = try siblingTelar(init.io, &telar_buffer);

    var client_options = prepared.frontendOptions();
    client_options.telar_executable = telar;
    client_options.machine = if (options.remote) |destination| .{ .remote = .{
        .destination = std.mem.span(destination),
        .arguments = prepared.command(),
    } } else .{ .local = .{
        .path = options.config,
        .disabled = options.no_config,
        .profile = options.profile,
        .fresh = options.fresh,
        .executable = telar,
    } };

    prepared.transferResources();
    const app = try headless.HeadlessClient.init(.{
        .gpa = init.gpa,
        .io = init.io,
        .host_size = .{
            .cols = headless_options.cols,
            .rows = headless_options.rows,
        },
        .client_identity = identity(init.io),
        .options = client_options,
    }, headless_options);
    defer app.deinit();

    return app.run();
}

fn siblingTelar(io: std.Io, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    var self_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = self_buffer[0..try std.process.executablePath(io, &self_buffer)];
    const directory = std.fs.path.dirname(self_path) orelse return error.NoExecutableDirectory;
    return std.fmt.bufPrint(buffer, "{s}/telar", .{directory});
}

// A fresh identity per process: a headless client never takes over a
// window's layout.
fn identity(io: std.Io) core.ClientIdentity {
    const now: u64 = @intCast(@max(0, std.Io.Clock.awake.now(io).toNanoseconds()));
    const pid = std.c.getpid();
    return @enumFromInt(std.hash.Wyhash.hash(now, std.mem.asBytes(&pid)) | 1);
}

fn collectArgs(init: std.process.Init, storage: *[pty.command_support.max_args][*:0]const u8) ![]const [*:0]const u8 {
    var iterator = init.minimal.args.iterate();
    _ = iterator.next();
    var len: usize = 0;
    while (iterator.next()) |arg| {
        if (len == storage.len) {
            return error.TooManyArguments;
        }

        storage[len] = arg.ptr;
        len += 1;
    }

    return storage[0..len];
}

fn dumpEchoTrace(init: std.process.Init) void {
    if (comptime build_options.echo_trace) {
        const directory = init.minimal.environ.getPosix("TELAR_ECHO_TRACE_DIR") orelse return;
        echo_recorder.dump(init.io, directory) catch {};
    }
}
