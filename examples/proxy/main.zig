const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const File = std.Io.File;

const ca = @import("ca.zig");
const capture_mod = @import("capture.zig");
const db = @import("db.zig");
const event = @import("event.zig");
const osc = @import("osc.zig");
const proxy = @import("proxy.zig");

// PTY proxy, iteration 2: two taps on one timeline.
//
//   input actor    stdin        -> Event.user_input
//   output actor   pty master   -> the terminal, plus the OSC 133 tap
//   signal actor   wake pipe    -> Event.resized
//   proxy actor    :PORT        -> Event.upstream_opened / _closed
//   main loop      consumes events, owns all mutable state, writes timeline.db
//
// The point of the merge is that the shell's commands and the child's outbound
// API calls land in one ordered stream, so "this request happened while that
// command was running" is a WHERE, not a reconstruction.
//
//   zig build run

const KB = event.KB;

/// Terminal ioctls, isolated per platform the way herdr keeps OS specifics in
/// `src/platform/<os>.rs` instead of sprinkling `#[cfg]` through core modules.
const TIOC = switch (builtin.os.tag) {
    .macos => struct {
        const GWINSZ: c_int = 0x40087468;
        const SWINSZ: c_int = @bitCast(@as(u32, 0x80087467));
        const SCTTY: c_int = 0x20007461;
    },
    .linux => struct {
        const GWINSZ: c_int = 0x5413;
        const SWINSZ: c_int = 0x5414;
        const SCTTY: c_int = 0x540E;
    },
    else => @compileError("unsupported platform"),
};

extern "c" fn openpty(amaster: *std.c.fd_t, aslave: *std.c.fd_t, name: ?[*]u8, termp: ?*const std.posix.termios, winp: ?*const std.posix.winsize) c_int;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// ---------------------------------------------------------------------------
// Host terminal
// ---------------------------------------------------------------------------

/// Saved so the terminal can be restored from anywhere, including paths that
/// never return normally. Globals because a restore must not need arguments.
var original: ?std.posix.termios = null;
var original_fd: ?std.c.fd_t = null;

fn restore() void {
    if (original) |orig| {
        if (original_fd) |fd| {
            std.posix.tcsetattr(fd, .FLUSH, orig) catch {};
        }
        original = null;
    }
}

fn makeRaw(fd: std.c.fd_t, termio: *std.posix.termios) !void {
    termio.lflag.ICANON = false; // Disable canonical mode
    termio.lflag.ECHO = false; // Disable echo
    termio.lflag.ISIG = false; // Disable signal generation
    termio.lflag.IEXTEN = false; // Disable extended input processing
    termio.iflag.IXON = false; // Disable flow control

    termio.iflag.ICRNL = false; // Disable carriage return to newline translation
    termio.iflag.BRKINT = false; // Disable break interrupt
    termio.iflag.INPCK = false; // Disable parity checking
    termio.iflag.ISTRIP = false; // Disable stripping of the eighth bit

    termio.oflag.OPOST = false; // Disable output processing

    termio.cflag.CSIZE = .CS8; // Set character size to 8 bits
    termio.cflag.PARENB = false; // Disable parity generation

    termio.cc[@intFromEnum(std.posix.V.MIN)] = 1; // Minimum characters per read
    termio.cc[@intFromEnum(std.posix.V.TIME)] = 0; // Block until a byte arrives

    try std.posix.tcsetattr(fd, .FLUSH, termio.*);
}

// ---------------------------------------------------------------------------
// PTY
// ---------------------------------------------------------------------------

const Pty = struct {
    master: std.c.fd_t,
    slave: std.c.fd_t,
};

fn openPty(host_tty: std.c.fd_t) !Pty {
    var ws: std.posix.winsize = undefined;
    if (std.c.ioctl(host_tty, TIOC.GWINSZ, &ws) != 0) {
        return error.GetWindowSizeFailed;
    }

    var master: std.c.fd_t = undefined;
    var slave: std.c.fd_t = undefined;
    if (openpty(&master, &slave, null, null, &ws) < 0) {
        return error.OpenPtyFailed;
    }

    return .{ .master = master, .slave = slave };
}

/// Copies the host terminal's size onto the pty. Sizing the master is what makes
/// the kernel raise SIGWINCH in the child's foreground process group.
fn syncWindowSize(host_tty: std.c.fd_t, master: std.c.fd_t) !void {
    var ws: std.posix.winsize = undefined;
    if (std.c.ioctl(host_tty, TIOC.GWINSZ, &ws) != 0) {
        return error.GetWindowSizeFailed;
    }
    if (std.c.ioctl(master, TIOC.SWINSZ, &ws) != 0) {
        return error.SetWindowSizeFailed;
    }
}

/// Forks and execs `command` on the slave side. Everything after the fork in the
/// child branch is async-signal-safe only: no `try`, no `defer`, no `return`,
/// because unwinding would run the parent's cleanup on the parent's terminal.
fn spawnChild(pty: Pty, child: *const Child) !std.c.pid_t {
    const pid = std.c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }
    if (pid > 0) {
        return pid;
    }

    _ = std.c.setsid();
    if (std.c.ioctl(pty.slave, TIOC.SCTTY, @as(c_int, 0)) != 0) {
        std.c._exit(1);
    }

    _ = std.c.dup2(pty.slave, std.c.STDIN_FILENO);
    _ = std.c.dup2(pty.slave, std.c.STDOUT_FILENO);
    _ = std.c.dup2(pty.slave, std.c.STDERR_FILENO);
    _ = std.c.close(pty.master);
    _ = std.c.close(pty.slave);

    _ = execvp(child.file, &child.argv);
    std.c._exit(127);
}

const ChildExit = union(enum) {
    exited: u8,
    signaled: std.c.SIG,
};

fn waitForChild(pid: std.c.pid_t) !ChildExit {
    var child_status: c_int = undefined;

    while (true) {
        const rc = std.c.waitpid(pid, &child_status, 0);
        if (rc > 0) {
            break;
        }

        switch (std.posix.errno(rc)) {
            .INTR => continue,
            .CHILD => return error.NoSuchChild,
            else => return error.WaitpidFailed,
        }
    }

    const status: u32 = @bitCast(child_status);
    if (std.posix.W.IFEXITED(status)) {
        return .{ .exited = std.posix.W.EXITSTATUS(status) };
    }
    if (std.posix.W.IFSIGNALED(status)) {
        return .{ .signaled = std.posix.W.TERMSIG(status) };
    }
    return error.UnexpectedChildStatus;
}

// ---------------------------------------------------------------------------
// Actors
// ---------------------------------------------------------------------------

/// Owns the host terminal's input and nothing else, like herdr's
/// `spawn_input_reader`. Keeping it off the main loop is what will let an
/// escape-sequence framer time its ESC disambiguation without competing with
/// rendering.
///
/// Reads stdin rather than the `/dev/tty` handle on purpose. On macOS a
/// descriptor opened from `/dev/tty` is the ctty clone device (rdev 2/0): `poll`
/// answers POLLNVAL on it and `kqueue` refuses to register it at all.
fn inputActor(io: Io, stdin: File, queue: *event.Queue) Io.Cancelable!void {
    while (true) {
        var chunk: event.Chunk = .{};
        chunk.len = stdin.readStreaming(io, &.{&chunk.bytes}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return,
        };
        queue.putOne(io, .{ .user_input = chunk }) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return,
        };
    }
}

/// Drains the pty master onto the host terminal. This is herdr's PtyIoActor read
/// side: the tap runs here, in the actor, so only parsed events reach the main
/// loop rather than every byte of output.
fn outputActor(io: Io, gpa: std.mem.Allocator, master: File, host_tty: File, rows: u16, cols: u16, queue: *event.Queue) Io.Cancelable!void {
    var buffer: [64 * KB]u8 = undefined;
    var scanner: osc.Scanner = .init(gpa);
    defer scanner.deinit();
    var last_title: event.CommandLine = .{};

    var capture: capture_mod.Capture = undefined;
    const capturing = if (capture.init(.{ .io = io, .allocator = gpa, .rows = rows, .cols = cols })) true else |_| false;
    defer if (capturing) capture.deinit();

    while (true) {
        const n = master.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            // macOS reports the slave closing as end of stream, Linux as EIO.
            else => break,
        };
        const chunk = buffer[0..n];

        // Scanner state survives the chunk boundary, which matters: the pty
        // hands over exactly 1 KiB at a time. Walking the markers with their
        // offsets is what lets the capture start at C and stop at D instead of
        // swallowing the prompt around them.
        scanner.feed(chunk);
        var cursor: usize = 0;
        while (scanner.next()) |marker| {
            const at = scanner.offsetIn(chunk);
            if (capturing) {
                capture.feed(chunk[cursor..at]);
            }
            cursor = at;

            const parsed: event.Event = switch (marker) {
                .title => |text| {
                    last_title.set(text);
                    continue;
                },
                .output_start => blk: {
                    if (capturing) {
                        capture.begin();
                    }
                    break :blk .{ .command_started = last_title };
                },
                .command_end => |status| blk: {
                    const result = if (capturing) capture.finish() else null;
                    break :blk .{ .command_finished = .{
                        .status = status,
                        .output = if (result) |r| r.text else null,
                        .truncated = if (result) |r| r.truncated else false,
                    } };
                },
                .prompt_start, .command_start => continue,
            };

            queue.putOne(io, parsed) catch |err| {
                // Ownership never transferred, so the text is ours to release.
                if (parsed == .command_finished) {
                    if (parsed.command_finished.output) |text| {
                        gpa.free(text);
                    }
                }
                switch (err) {
                    error.Canceled => |e| return e,
                    else => return,
                }
            };
        }
        if (capturing) {
            capture.feed(chunk[cursor..]);
        }

        host_tty.writeStreamingAll(io, chunk) catch break;
    }

    queue.putOne(io, .child_gone) catch {};
}

/// The signal half of the self-pipe. A handler may only touch async-signal-safe
/// calls, so it writes one byte and this actor turns that into an event.
var winch_pipe_write: std.c.fd_t = -1;

fn onWindowChange(_: std.posix.SIG) callconv(.c) void {
    const byte = [1]u8{0};
    _ = std.c.write(winch_pipe_write, &byte, byte.len);
}

fn signalActor(io: Io, wake: File, queue: *event.Queue) Io.Cancelable!void {
    var drain: [64]u8 = undefined;

    while (true) {
        _ = wake.readStreaming(io, &.{&drain}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return,
        };
        queue.putOne(io, .resized) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return,
        };
    }
}

fn installWindowChangeHandler(write_fd: std.c.fd_t) void {
    winch_pipe_write = write_fd;

    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = onWindowChange },
        .mask = std.posix.sigemptyset(),
        // SA_RESTART so the signal does not surface as EINTR inside unrelated
        // reads; the pipe write is what carries the news.
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &action, null);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const default_shell = "/bin/zsh";
const timeline_path = "timeline.db";
const max_argv = 32;

/// The command to run in the pty. `pty_proxy claude --resume` runs Claude Code
/// under the taps; with no arguments it falls back to an interactive shell,
/// which is what the OSC 133 command log is written against.
const Child = struct {
    file: [*:0]const u8,
    argv: [max_argv:null]?[*:0]const u8,

    fn fromArgs(init: std.process.Init) Child {
        var child: Child = .{ .file = default_shell, .argv = @splat(null) };
        var it = init.minimal.args.iterate();
        _ = it.next(); // argv[0], ours

        var n: usize = 0;
        while (it.next()) |arg| {
            if (n == max_argv - 1) {
                break;
            }
            if (n == 0) {
                child.file = arg.ptr;
            }
            child.argv[n] = arg.ptr;
            n += 1;
        }
        if (n == 0) {
            child.argv[0] = default_shell;
        }
        return child;
    }
};

/// No shell emits OSC 133 on its own; terminal emulators ship an rc file that
/// installs the hooks. Borrowing Ghostty's is enough here — a real herdr ships
/// its own and supports more than zsh.
const shell_integration_zdotdir =
    "/Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration/zsh";

/// Points the child's zsh at that rc file. `overwrite = 0` keeps a ZDOTDIR the
/// user already set, and a missing integration directory is left alone rather
/// than starting a shell with no rc file at all.
fn installShellIntegration(io: Io) void {
    std.Io.Dir.accessAbsolute(io, shell_integration_zdotdir, .{}) catch return;
    _ = setenv("ZDOTDIR", shell_integration_zdotdir, 0);
}

const ca_key_path = "mitm-ca.key";
const ca_cert_path = "mitm-ca.crt";
/// System roots plus ours, for the runtimes whose variable *replaces* the trust
/// store instead of extending it.
const ca_bundle_path = "mitm-ca-bundle.crt";

/// Tells the child's runtimes to trust our CA. Each ecosystem reads a different
/// variable, and none of them read the system keychain by default.
fn exportTrustEnv() void {
    var buf: [1024]u8 = undefined;
    if (std.c.getcwd(&buf, buf.len) == null) {
        return;
    }
    const cwd = std.mem.sliceTo(&buf, 0);

    var ca_buf: [1100]u8 = undefined;
    const ca_path = std.fmt.bufPrintZ(&ca_buf, "{s}/{s}", .{ cwd, ca_cert_path }) catch return;
    var bundle_buf: [1100]u8 = undefined;
    const bundle_path = std.fmt.bufPrintZ(&bundle_buf, "{s}/{s}", .{ cwd, ca_bundle_path }) catch return;

    // Additive: node adds these to its built-in roots.
    _ = setenv("NODE_EXTRA_CA_CERTS", ca_path, 1);

    // Replacing: these name *the* trust store, so they get the full bundle.
    for ([_][*:0]const u8{
        "SSL_CERT_FILE", // openssl, python
        "CURL_CA_BUNDLE",
        "REQUESTS_CA_BUNDLE",
        "AWS_CA_BUNDLE",
    }) |name| {
        _ = setenv(name, bundle_path, 1);
    }
}

/// Points the child at our proxy. Overwrites on purpose: an inherited proxy
/// would hide exactly the traffic this PoC exists to see.
fn exportProxyEnv(port: u16) void {
    var buf: [64]u8 = undefined;
    const url = std.fmt.bufPrintZ(&buf, "http://127.0.0.1:{d}", .{port}) catch return;
    for ([_][*:0]const u8{ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy" }) |name| {
        _ = setenv(name, url, 1);
    }
    // Node's global fetch ignores the proxy variables unless told to read them.
    // Without this, Claude Code talks to the API directly and the tap sees
    // nothing.
    _ = setenv("NODE_USE_ENV_PROXY", "1", 1);
}

/// Frees anything an event still owns. Events carry heap payloads across the
/// queue, so whoever ends up holding one is responsible for it.
fn releaseEvent(gpa: std.mem.Allocator, item: event.Event) void {
    switch (item) {
        .command_finished => |finished| if (finished.output) |text| gpa.free(text),
        .upstream_exchange => |exchange| if (exchange.detail) |text| gpa.free(text),
        else => {},
    }
}

/// Empties whatever the actors queued but the main loop never reached. Without
/// this, a child that exits while requests are still in flight leaks every
/// captured body still waiting in the ring.
fn drainQueue(io: Io, gpa: std.mem.Allocator, queue: *event.Queue) void {
    queue.close(io);

    var leftovers: [16]event.Event = undefined;
    while (true) {
        // `min = 0` makes this a non-blocking take of whatever is there.
        const n = queue.get(io, &leftovers, 0) catch break;
        if (n == 0) {
            break;
        }
        for (leftovers[0..n]) |item| releaseEvent(gpa, item);
    }
}

/// A command between its OSC 133 C and D markers.
const Running = struct {
    id: i64,
    started_at: Io.Timestamp,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    original_fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0) catch |err| {
        std.debug.print("Failed to open /dev/tty: {s}\n", .{@errorName(err)});
        return err;
    };
    const host_fd = original_fd.?;
    defer _ = std.c.close(host_fd);

    original = try std.posix.tcgetattr(host_fd);
    defer restore();

    var session_buf: [48]u8 = undefined;
    const session_id = std.fmt.bufPrint(&session_buf, "{d}-{d}", .{
        std.c.getpid(),
        Io.Timestamp.now(io, .real).toMilliseconds(),
    }) catch "session";

    var timeline = try db.Timeline.open(timeline_path, session_id);
    defer timeline.close();

    const pty = try openPty(host_fd);
    installShellIntegration(io);

    // Reserve the port with plain syscalls before the fork, so the child can
    // inherit HTTPS_PROXY and no `Io` worker thread is alive across the fork.
    // The CA has to exist before the fork too: the child inherits the env vars
    // that point its runtimes at it.
    const authority: ?ca.Authority = ca.Authority.loadOrCreate(.{ .io = io, .allocator = init.gpa }, .{ .key = ca_key_path, .certificate = ca_cert_path }) catch null;

    const proxy_port = if (authority != null) proxy.reservePort(8099, 20) else null;
    if (proxy_port) |port| {
        if (authority) |a| {
            a.writeBundle(.{ .io = io, .allocator = init.gpa }, ca_bundle_path) catch {};
        }
        exportProxyEnv(port);
        exportTrustEnv();
    }

    const child = Child.fromArgs(init);
    const pid = try spawnChild(pty, &child);
    _ = std.c.close(pty.slave); // The parent must let go, or the master never sees EOF.

    var winch_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&winch_pipe) != 0) {
        return error.PipeFailed;
    }
    defer _ = std.c.close(winch_pipe[0]);
    defer _ = std.c.close(winch_pipe[1]);
    installWindowChangeHandler(winch_pipe[1]);
    // Disarm before the pipe closes, so a late SIGWINCH cannot write into a
    // descriptor number that has already been recycled.
    defer winch_pipe_write = -1;

    var winsize: std.posix.winsize = undefined;
    if (std.c.ioctl(host_fd, TIOC.GWINSZ, &winsize) != 0) {
        return error.GetWindowSizeFailed;
    }

    var tio = original.?;
    try makeRaw(host_fd, &tio);

    const blocking: File.Flags = .{ .nonblocking = false };
    const host_tty: File = .{ .handle = host_fd, .flags = blocking };
    const master: File = .{ .handle = pty.master, .flags = blocking };
    const wake: File = .{ .handle = winch_pipe[0], .flags = blocking };

    if (proxy_port != null) {
        try host_tty.writeStreamingAll(
            io,
            "\x1b]2;telar proxy: HTTPS interception active\x07" ++
                "\r\n\x1b[1;37;41m TELAR HTTPS INTERCEPTION ACTIVE " ++
                "(bodies are not stored) \x1b[0m\r\n",
        );
    }

    var slots: [64]event.Event = undefined;
    var queue: event.Queue = .init(&slots);

    var actors: Io.Group = .init;
    defer actors.cancel(io);

    try actors.concurrent(io, inputActor, .{ io, File.stdin(), &queue });
    try actors.concurrent(io, outputActor, .{ io, init.gpa, master, host_tty, winsize.row, winsize.col, &queue });
    try actors.concurrent(io, signalActor, .{ io, wake, &queue });
    if (proxy_port) |port| {
        try actors.concurrent(io, proxy.serve, .{ io, port, authority.?, init.gpa, &queue });
    }

    // The main loop owns every mutable decision and is the single ordering
    // authority for the timeline. Actors only move bytes.
    var next_command_id: i64 = 1;
    var running: ?Running = null;

    loop: while (true) {
        const item = queue.getOne(io) catch break;
        const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();

        switch (item) {
            .user_input => |chunk| master.writeStreamingAll(io, chunk.slice()) catch break :loop,

            .command_started => |command| {
                const id = next_command_id;
                next_command_id += 1;
                running = .{ .id = id, .started_at = Io.Timestamp.now(io, .awake) };
                timeline.append(.{
                    .at_ms = now_ms,
                    .kind = .command_started,
                    .ref = id,
                    .command = command.slice(),
                });
            },

            .command_finished => |finished| {
                // The producer handed us the text; releasing it is now our job,
                // on every path out of this branch.
                defer if (finished.output) |text| init.gpa.free(text);

                // A D without a matching C means the shell reported an end for
                // a command that never started; there is nothing to close.
                const open = running orelse continue;
                running = null;
                const elapsed = open.started_at.durationTo(Io.Timestamp.now(io, .awake));
                timeline.append(.{
                    .at_ms = now_ms,
                    .kind = .command_finished,
                    .ref = open.id,
                    .exit_status = if (finished.status) |code| code else null,
                    .duration_ms = elapsed.toMilliseconds(),
                    // Terminal output may contain environment secrets. The
                    // example observes byte counts and command lifecycle but
                    // does not persist arbitrary output.
                    .output = null,
                    .truncated = if (finished.truncated) 1 else 0,
                });
            },

            .upstream_opened => |up| timeline.append(.{
                .at_ms = now_ms,
                .kind = .upstream_opened,
                .ref = @intCast(up.id),
                .host = up.host.slice(),
                .port = up.port,
            }),

            .upstream_exchange => |exchange| {
                defer if (exchange.detail) |text| init.gpa.free(text);
                timeline.append(.{
                    .at_ms = now_ms,
                    .kind = .upstream_exchange,
                    .ref = @intCast(exchange.id),
                    .host = exchange.host.slice(),
                    .port = exchange.port,
                    .bytes_up = @intCast(exchange.request_bytes),
                    .bytes_down = @intCast(exchange.response_bytes),
                    .duration_ms = exchange.duration_ms,
                    .output = exchange.detail,
                    .truncated = if (exchange.truncated) 1 else 0,
                });
            },

            .upstream_closed => |up| timeline.append(.{
                .at_ms = now_ms,
                .kind = .upstream_closed,
                .ref = @intCast(up.id),
                .duration_ms = up.duration_ms,
                .bytes_up = @intCast(up.bytes_up),
                .bytes_down = @intCast(up.bytes_down),
            }),

            .resized => syncWindowSize(host_fd, pty.master) catch {},
            .child_gone => break :loop,
        }
    }

    actors.cancel(io);
    drainQueue(io, init.gpa, &queue);

    const exit = try waitForChild(pid);

    restore();
    switch (exit) {
        .exited => |code| std.debug.print("child exited with status {d}\n", .{code}),
        .signaled => |sig| std.debug.print("child killed by {t}\n", .{sig}),
    }
    if (proxy_port) |port| {
        std.debug.print("proxy listened on 127.0.0.1:{d}\n", .{port});
    } else {
        std.debug.print("no free proxy port; upstream traffic was not observed\n", .{});
    }
    std.debug.print("timeline: {s} (session {s})\n", .{ timeline_path, session_id });
    if (authority == null) {
        std.debug.print("no CA: TLS interception disabled\n", .{});
    }
}
