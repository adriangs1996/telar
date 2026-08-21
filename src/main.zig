const std = @import("std");
const vt = @import("ghostty-vt");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");

const Io = std.Io;
const File = Io.File;
const platform = frontend.platform;
const pace = frontend.pace;
const term = frontend.term;
const pty = backend.pty;

const version = "0.0.0";
const output_chunk_size = 16 * 1024;

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
pub const std_options: std.Options = .{ .log_level = .err };

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn setenv(
    name: [*:0]const u8,
    value: [*:0]const u8,
    overwrite: c_int,
) c_int;

const Output = struct {
    bytes: [output_chunk_size]u8 = undefined,
    len: u16 = 0,

    fn slice(output: *const Output) []const u8 {
        return output.bytes[0..output.len];
    }
};

const Message = union(enum) {
    output: Output,
    resize,
    child_gone,

    fn coalesceKey(message: Message) ?u32 {
        return switch (message) {
            .resize => 1,
            .output, .child_gone => null,
        };
    }
};

const Cli = union(enum) {
    help,
    version,
    run: pty.Command,

    fn parse(args: []const [*:0]const u8) !Cli {
        if (args.len == 0) return error.MissingArgvZero;
        if (args.len == 1) return .{ .run = try defaultShell() };

        const first = std.mem.span(args[1]);
        if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h"))
            return .help;
        if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V"))
            return .version;

        const command_start: usize = if (std.mem.eql(u8, first, "--")) 2 else 1;
        return .{ .run = try pty.Command.fromArgv(args[command_start..]) };
    }
};

fn defaultShell() !pty.Command {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = getenv("SHELL") orelse return pty.Command.fromArgv(&.{fallback});
    const shell: [*:0]const u8 = configured;
    if (shell[0] == 0) return pty.Command.fromArgv(&.{fallback});
    return pty.Command.fromArgv(&.{shell});
}

fn collectArgs(init: std.process.Init, storage: *[pty.max_args][*:0]const u8) ![]const [*:0]const u8 {
    var iterator = init.minimal.args.iterate();
    var len: usize = 0;
    while (iterator.next()) |arg| {
        if (len == storage.len) return error.TooManyArguments;
        storage[len] = arg.ptr;
        len += 1;
    }
    return storage[0..len];
}

fn inputActor(io: Io, master: File) Io.Cancelable!void {
    const stdin = File.stdin();
    var bytes: [4096]u8 = undefined;

    while (true) {
        const len = stdin.readStreaming(io, &.{&bytes}) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            else => return,
        };
        if (len == 0) return;

        master.writeStreamingAll(io, bytes[0..len]) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            else => return,
        };
    }
}

fn outputActor(
    io: Io,
    master: File,
    queue: *Io.Queue(Message),
) Io.Cancelable!void {
    while (true) {
        var output: Output = .{};
        output.len = @intCast(master.readStreaming(io, &.{&output.bytes}) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            // Linux reports EIO when the slave side closes. macOS reports EOF.
            else => break,
        });
        if (output.len == 0) break;

        queue.putOne(io, .{ .output = output }) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            error.Closed => return,
        };
    }

    queue.putOne(io, .child_gone) catch {};
}

fn resizeActor(
    io: Io,
    watcher: *platform.ResizeWatcher,
    queue: *Io.Queue(Message),
) Io.Cancelable!void {
    while (true) {
        try watcher.wait(io);
        queue.putOne(io, .resize) catch |err| switch (err) {
            error.Canceled => |canceled| return canceled,
            error.Closed => return,
        };
    }
}

fn sizeOf(tty: *const platform.Tty) pty.Size {
    const size = tty.size();
    return (pty.Size{ .cols = size.cols, .rows = size.rows }).valid();
}

fn drawPane(
    gpa: std.mem.Allocator,
    render_state: *vt.RenderState,
    terminal: *vt.Terminal,
    screen: *term.Screen,
    writer: *Io.Writer,
    force: bool,
) !void {
    try render_state.update(gpa, terminal);
    _ = backend.blit.blit(screen.buffer(), screen.buffer().area(), render_state, .{
        .cursor = true,
        .force = force,
    });
    screen.cursor = null;
    _ = try screen.flush(writer);
}

fn run(init: std.process.Init, command: *const pty.Command) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var tty = platform.Tty.open() catch |err| {
        std.debug.print("telar needs a terminal: {s}\n", .{@errorName(err)});
        return err;
    };
    defer tty.deinit();

    var tty_file = tty.writeHandle();
    var output_buffer: [512 * 1024]u8 = undefined;
    var output_writer = tty_file.writer(io, &output_buffer);
    const writer = &output_writer.interface;

    try writer.writeAll(platform.pane_enter_sequence);
    try writer.flush();
    defer {
        writer.writeAll(platform.pane_leave_sequence) catch {};
        writer.flush() catch {};
    }

    const initial_size = sizeOf(&tty);

    // The child talks to the emulator embedded in telar, not directly to the
    // host terminal. Advertising the host's TERM would be a false promise.
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("TERM_PROGRAM", "telar", 1);

    var session = try pty.Session.spawn(command, initial_size);
    defer session.deinit();
    const master = session.file();

    var terminal = try vt.Terminal.init(io, gpa, .{
        .cols = initial_size.cols,
        .rows = initial_size.rows,
    });
    defer terminal.deinit(gpa);

    // One stream for the whole process. Parser state must survive PTY read
    // boundaries because an escape sequence may be split across any two reads.
    var stream = terminal.vtStream();
    defer stream.deinit();

    var render_state: vt.RenderState = .empty;
    defer render_state.deinit(gpa);

    var screen = try term.Screen.init(gpa, initial_size.cols, initial_size.rows);
    defer screen.deinit();

    var watcher = try platform.ResizeWatcher.init(&tty);
    defer watcher.deinit();

    var queue_storage: [64]Message = undefined;
    var queue: Io.Queue(Message) = .init(&queue_storage);
    defer queue.close(io);

    var actors: Io.Group = .init;
    defer actors.cancel(io);
    try actors.concurrent(io, inputActor, .{ io, master });
    try actors.concurrent(io, outputActor, .{ io, master, &queue });
    try actors.concurrent(io, resizeActor, .{ io, &watcher, &queue });

    // Clear the alternate screen before waiting for the shell's first byte.
    // This is not recorded in the pacer, so an immediate prompt is not delayed.
    try drawPane(gpa, &render_state, &terminal, &screen, writer, true);

    var pacer: pace.Pacer = .{};
    var batch: [64]Message = undefined;
    var child_gone = false;

    while (!child_gone) {
        var count = queue.get(io, &batch, 1) catch break;
        var absorbed: usize = 0;
        var changed = false;
        var force = false;

        while (true) {
            const before = count;
            count = pace.coalesce(Message, batch[0..count], Message.coalesceKey);
            pacer.noteDropped(before - count);
            absorbed += count;

            for (batch[0..count]) |message| switch (message) {
                .output => |output| {
                    stream.nextSlice(output.slice());
                    changed = true;
                },
                .resize => {
                    const next_size = sizeOf(&tty);
                    session.resize(next_size) catch {};
                    try terminal.resize(gpa, .{
                        .cols = next_size.cols,
                        .rows = next_size.rows,
                    });
                    try screen.resize(next_size.cols, next_size.rows);
                    changed = true;
                    force = true;
                },
                .child_gone => child_gone = true,
            };

            if (child_gone) break;

            const wait_ns = pacer.waitFor(monotonic(io));
            if (wait_ns == 0) break;
            pacer.noteThrottled();
            io.sleep(.fromNanoseconds(@intCast(wait_ns)), .awake) catch break;

            count = queue.get(io, &batch, 0) catch break;
            if (count == 0) break;
        }

        if (changed) {
            try drawPane(gpa, &render_state, &terminal, &screen, writer, force);
            pacer.record(monotonic(io), absorbed);
        }
    }

    actors.cancel(io);
    return (try session.wait()).code();
}

fn monotonic(io: Io) u64 {
    const timestamp = Io.Timestamp.now(io, .awake);
    return @intCast(@max(timestamp.nanoseconds, 0));
}

const usage =
    \\Usage: telar [command [args...]]
    \\
    \\Run an interactive shell inside telar's single-pane UI.
    \\With a command, run that command instead of $SHELL.
    \\
    \\Options:
    \\  -h, --help       Show this help
    \\  -V, --version    Show the version
    \\  --               Stop parsing telar options
    \\
;

pub fn main(init: std.process.Init) !void {
    var arg_storage: [pty.max_args][*:0]const u8 = undefined;
    const args = try collectArgs(init, &arg_storage);

    switch (try Cli.parse(args)) {
        .help => try File.stdout().writeStreamingAll(init.io, usage),
        .version => try File.stdout().writeStreamingAll(init.io, "telar " ++ version ++ "\n"),
        .run => |command| {
            const code = try run(init, &command);
            std.process.exit(code);
        },
    }
}

test "CLI defaults to the configured shell" {
    const args = [_][*:0]const u8{"telar"};
    const cli = try Cli.parse(&args);
    try std.testing.expect(cli == .run);
    try std.testing.expect(cli.run.argv[0] != null);
}

test "CLI forwards a command without a shell" {
    const args = [_][*:0]const u8{ "telar", "/bin/sh", "-c", "exit 9" };
    const cli = try Cli.parse(&args);

    try std.testing.expect(cli == .run);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.file));
    try std.testing.expectEqualStrings("exit 9", std.mem.span(cli.run.argv[2].?));
}

test "CLI delimiter permits option-shaped commands" {
    const args = [_][*:0]const u8{ "telar", "--", "-command" };
    const cli = try Cli.parse(&args);
    try std.testing.expectEqualStrings("-command", std.mem.span(cli.run.file));
}

test "CLI rejects an empty command after the delimiter" {
    const args = [_][*:0]const u8{ "telar", "--" };
    try std.testing.expectError(error.MissingCommand, Cli.parse(&args));
}
