const std = @import("std");
const builtin = @import("builtin");

const mac = if (builtin.os.tag == .macos) @cImport({
    @cInclude("libproc.h");
}) else struct {};

const File = std.Io.File;

pub const max_args = 64;

const TIOC = switch (builtin.os.tag) {
    .macos => struct {
        const SWINSZ: c_int = @bitCast(@as(u32, 0x80087467));
        const SCTTY: c_int = 0x20007461;
        /// TIOCFLUSH, pointer to FREAD | FWRITE.
        const FLUSH: c_int = @bitCast(@as(u32, 0x80047410));
    },
    .linux => struct {
        const SWINSZ: c_int = 0x5414;
        const SCTTY: c_int = 0x540E;
        /// TCFLSH, immediate TCIOFLUSH argument.
        const FLUSH: c_int = 0x540B;
    },
    else => @compileError("telar's PTY bootstrap currently supports macOS and Linux"),
};

const WAITID = switch (builtin.os.tag) {
    .macos => struct {
        const P_PID: c_int = 1;
        const WNOHANG: c_int = 0x00000001;
        const WEXITED: c_int = 0x00000004;
        const WSTOPPED: c_int = 0x00000008;
        const WCONTINUED: c_int = 0x00000010;
        const WNOWAIT: c_int = 0x00000020;
    },
    .linux => struct {
        const P_PID: c_int = 1;
        const WNOHANG: c_int = 0x00000001;
        const WSTOPPED: c_int = 0x00000002;
        const WCONTINUED: c_int = 0x00000008;
        const WEXITED: c_int = 0x00000004;
        const WNOWAIT: c_int = 0x01000000;
    },
    else => @compileError("telar's PTY bootstrap currently supports macOS and Linux"),
};

/// `siginfo.si_code` values for SIGCHLD, identical on macOS and Linux.
const CLD = struct {
    const EXITED: c_int = 1;
    const KILLED: c_int = 2;
    const DUMPED: c_int = 3;
};

extern "c" fn waitid(
    idtype: c_int,
    id: c_uint,
    infop: *std.c.siginfo_t,
    options: c_int,
) c_int;

extern "c" fn openpty(
    amaster: *std.c.fd_t,
    aslave: *std.c.fd_t,
    name: ?[*]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const std.posix.winsize,
) c_int;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
extern "c" var environ: [*:null]?[*:0]u8;
extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;

/// The immutable environment presented by Telar's terminal to every child.
/// It is built once by the runtime, before pane launches enter the interactive
/// path, and borrowed by `Command` through `spawn`.
pub const Environment = struct {
    block: std.process.Environ.PosixBlock,
    gpa: std.mem.Allocator,

    pub const Override = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Configuration = struct {
        term_program: []const u8,
        overrides: []const Override,
    };

    pub fn init(gpa: std.mem.Allocator, inherited: std.process.Environ, term_program: []const u8) !Environment {
        return initWithOverrides(gpa, inherited, .{ .term_program = term_program, .overrides = &.{} });
    }

    /// Creates the immutable child environment after removing runtime-only
    /// authority and applying bounded pane-specific overrides.
    ///
    /// ```zig
    /// var environment = try Environment.initWithOverrides(gpa, inherited, .{ .term_program = "telar", .overrides = overrides });
    /// ```
    pub fn initWithOverrides(gpa: std.mem.Allocator, inherited: std.process.Environ, configuration: Configuration) !Environment {
        var map = try inherited.createMap(gpa);
        defer map.deinit();

        // terminal-browser otherwise treats this nested PTY as Ghostty and
        // writes Ghostty pane-discovery OSC 7 between Kitty image chunks.
        _ = map.swapRemove("GHOSTTY_RESOURCES_DIR");
        // Runtime authority is never ambient pane state.
        _ = map.swapRemove("TELAR_SOCKET");
        try map.put("TERM", "xterm-256color");
        try map.put("TERM_PROGRAM", configuration.term_program);
        for (configuration.overrides) |entry| try map.put(entry.name, entry.value);

        const block = try map.createPosixBlock(gpa, .{});
        return .{
            .block = block,
            .gpa = gpa,
        };
    }

    pub fn deinit(environment: *Environment) void {
        for (environment.block.slice) |entry| {
            const bytes = std.mem.span(@constCast(entry.?));
            std.crypto.secureZero(u8, bytes);
            environment.gpa.free(bytes);
        }
        environment.gpa.free(environment.block.slice);
        environment.* = undefined;
    }
};

pub const Size = struct {
    cols: u16,
    rows: u16,
    cell_width_px: u16 = 0,
    cell_height_px: u16 = 0,

    pub fn valid(size: Size) Size {
        return .{
            .cols = if (size.cols == 0) 80 else size.cols,
            .rows = if (size.rows == 0) 24 else size.rows,
            .cell_width_px = size.cell_width_px,
            .cell_height_px = size.cell_height_px,
        };
    }
};

/// A borrowed command description. The argument strings must outlive `spawn`.
pub const Command = struct {
    file: [*:0]const u8,
    argv: [max_args:null]?[*:0]const u8 = @splat(null),
    cwd: ?[*:0]const u8 = null,
    environment: ?*const Environment = null,

    pub fn fromArgv(args: []const [*:0]const u8) !Command {
        if (args.len == 0) return error.MissingCommand;
        // `argv` holds `max_args` slots plus a null sentinel, so exactly
        // `max_args` arguments fit.
        if (args.len > max_args) return error.TooManyArguments;

        var command: Command = .{ .file = args[0] };
        for (args, 0..) |arg, index| command.argv[index] = arg;
        return command;
    }
};

pub const Exit = union(enum) {
    exited: u8,
    signaled: std.posix.SIG,

    pub fn code(exit: Exit) u8 {
        return switch (exit) {
            .exited => |status| status,
            .signaled => |signal| @intCast(@min(
                128 + @intFromEnum(signal),
                std.math.maxInt(u8),
            )),
        };
    }
};

/// The process and PTY master owned by one runtime pane.
pub const Session = struct {
    master: std.c.fd_t,
    pid: std.c.pid_t,
    reaped: std.atomic.Value(bool) = .init(false),

    pub fn spawn(command: *const Command, initial_size: Size) !Session {
        const cwd_fd: ?std.c.fd_t = if (command.cwd) |cwd_path|
            std.posix.openat(std.posix.AT.FDCWD, std.mem.span(cwd_path), .{
                .ACCMODE = .RDONLY,
                .CLOEXEC = true,
                .DIRECTORY = true,
            }, 0) catch return error.InvalidWorkingDirectory
        else
            null;
        defer {
            if (cwd_fd) |fd| _ = std.c.close(fd);
        }

        const size = initial_size.valid();
        var window: std.posix.winsize = .{
            .row = size.rows,
            .col = size.cols,
            .xpixel = std.math.mul(u16, size.cols, size.cell_width_px) catch
                std.math.maxInt(u16),
            .ypixel = std.math.mul(u16, size.rows, size.cell_height_px) catch
                std.math.maxInt(u16),
        };

        var master: std.c.fd_t = undefined;
        var slave: std.c.fd_t = undefined;
        if (openpty(&master, &slave, null, null, &window) < 0) return error.OpenPtyFailed;
        errdefer _ = std.c.close(master);
        errdefer _ = std.c.close(slave);

        // Close-on-exec keeps this pair out of every *other* pane's child:
        // without it each spawned process inherits every older master and can
        // read its siblings' terminals. The child's own copies survive
        // because `dup2` onto stdio clears the flag on the duplicates.
        _ = std.c.fcntl(master, std.c.F.SETFD, @as(c_int, 1)); // FD_CLOEXEC
        _ = std.c.fcntl(slave, std.c.F.SETFD, @as(c_int, 1)); // FD_CLOEXEC

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            childExec(.{ .master = master, .slave = slave, .cwd_fd = cwd_fd, .command = command });
        }

        _ = std.c.close(slave);
        return .{ .master = master, .pid = pid };
    }

    pub fn file(session: *const Session) File {
        return .{
            .handle = session.master,
            .flags = .{ .nonblocking = false },
        };
    }

    /// Returns whether the session leader currently owns the terminal. A
    /// foreground job gets a different process group, regardless of shell.
    pub fn shellForeground(session: *const Session) ?bool {
        if (session.master < 0) return null;
        const foreground = tcgetpgrp(session.master);
        if (foreground < 0) return null;
        return foreground == session.pid;
    }

    /// Returns the foreground process group controlling the slave side. The
    /// observation worker uses this constant-cost signal before inspecting
    /// any native process metadata.
    pub fn foregroundProcessGroup(session: *const Session) ?std.c.pid_t {
        if (session.master < 0) return null;
        const foreground = tcgetpgrp(session.master);
        return if (foreground > 0) foreground else null;
    }

    /// Reads the session leader's cwd without asking the shell to publish it.
    pub fn cwd(session: *const Session, buffer: []u8) ?[]const u8 {
        return switch (builtin.os.tag) {
            .macos => cwdMacos(session.pid, buffer),
            .linux => cwdLinux(session.pid, buffer),
            else => null,
        };
    }

    /// Resizing the master updates the kernel's PTY state and sends SIGWINCH
    /// to the foreground process group on the slave side.
    pub fn resize(session: *Session, next_size: Size) !void {
        const size = next_size.valid();
        var window: std.posix.winsize = .{
            .row = size.rows,
            .col = size.cols,
            .xpixel = std.math.mul(u16, size.cols, size.cell_width_px) catch
                std.math.maxInt(u16),
            .ypixel = std.math.mul(u16, size.rows, size.cell_height_px) catch
                std.math.maxInt(u16),
        };
        if (std.c.ioctl(session.master, TIOC.SWINSZ, &window) != 0)
            return error.SetWindowSizeFailed;
    }

    pub fn wait(session: *Session) !Exit {
        if (session.reaped.load(.acquire)) return error.ChildAlreadyReaped;

        // Observe the exit without releasing the PID (WNOWAIT), publish the
        // reaped flag, and only then release the zombie. A concurrent
        // `shutdown` that reads a stale `false` therefore signals a PID that
        // is still held by the zombie, never one the kernel may have reused.
        try waitObserve(session.pid);
        session.reaped.store(true, .release);
        return waitPid(session.pid);
    }

    /// Make every blocking operation on the session able to finish.
    ///
    /// The runtime calls this before cancelling its actors: `waitpid` is a
    /// blocking libc call and cannot be cancelled by `Io.Select`, so the child
    /// has to be terminated before the actor waiting for it can be joined.
    ///
    /// Deliberately does NOT close the master. Child death releases a blocked
    /// master *read* (EOF), but a master *write* blocked on a full slave
    /// input queue survives it, and Darwin's close then waits behind that
    /// write forever. The write actor is released by Io cancellation instead,
    /// and the master closes in `deinit` once every actor has been joined.
    pub fn shutdown(session: *Session) void {
        if (!session.reaped.load(.acquire)) _ = std.c.kill(session.pid, .KILL);
    }

    fn closeMaster(session: *Session) void {
        if (session.master >= 0) {
            // A master write blocked on a full slave input queue survives
            // even the child's death, and Darwin's close then waits behind
            // it forever. Flushing both queues wakes the writer first.
            flushPty(session.master);
            _ = std.c.close(session.master);
            session.master = -1;
        }
    }

    pub fn deinit(session: *Session) void {
        session.closeMaster();
        if (!session.reaped.load(.acquire)) {
            // The UI can only reach this path after an internal failure. The
            // child must not survive detached from the PTY that telar owned.
            _ = std.c.kill(session.pid, .KILL);
            _ = waitPid(session.pid) catch {};
            session.reaped.store(true, .release);
        }
    }
};

fn cwdMacos(pid: std.c.pid_t, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    var info: mac.struct_proc_vnodepathinfo = undefined;
    const size: c_int = @intCast(@sizeOf(@TypeOf(info)));
    if (mac.proc_pidinfo(pid, mac.PROC_PIDVNODEPATHINFO, 0, &info, size) != size) return null;
    const source = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
    if (source.len == 0 or source.len > buffer.len) return null;
    @memcpy(buffer[0..source.len], source);
    return buffer[0..source.len];
}

fn cwdLinux(pid: std.c.pid_t, buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/cwd", .{pid}) catch return null;
    const result = std.c.readlinkat(std.posix.AT.FDCWD, path.ptr, buffer.ptr, buffer.len);
    if (result < 0) return null;
    return buffer[0..@intCast(result)];
}

/// Only async-signal-safe calls are allowed between fork and exec. In
/// particular, no allocator or error unwinding may run in this branch.
const ChildExec = struct {
    master: std.c.fd_t,
    slave: std.c.fd_t,
    cwd_fd: ?std.c.fd_t,
    command: *const Command,
};

fn childExec(child: ChildExec) noreturn {
    const master = child.master;
    const slave = child.slave;
    const cwd_fd = child.cwd_fd;
    const command = child.command;

    if (std.c.setsid() < 0) std.c._exit(1);
    if (std.c.ioctl(slave, TIOC.SCTTY, @as(c_int, 0)) != 0) std.c._exit(1);
    if (cwd_fd) |fd| if (std.c.fchdir(fd) != 0) std.c._exit(126);

    if (std.c.dup2(slave, std.c.STDIN_FILENO) < 0) std.c._exit(1);
    if (std.c.dup2(slave, std.c.STDOUT_FILENO) < 0) std.c._exit(1);
    if (std.c.dup2(slave, std.c.STDERR_FILENO) < 0) std.c._exit(1);

    _ = std.c.close(master);
    if (slave > std.c.STDERR_FILENO) _ = std.c.close(slave);

    // `fork` gave this child a private address space. Repointing libc's
    // environment here cannot race with the runtime and lets `execvp` retain
    // its existing PATH search and ENOEXEC fallback semantics.
    if (command.environment) |environment| switch (builtin.os.tag) {
        .macos => _NSGetEnviron().* = @ptrCast(@constCast(environment.block.slice.ptr)),
        .linux => environ = @ptrCast(@constCast(environment.block.slice.ptr)),
        else => unreachable,
    };

    _ = execvp(command.file, &command.argv);
    std.c._exit(127);
}

fn flushPty(master: std.c.fd_t) void {
    switch (builtin.os.tag) {
        .macos => {
            var queues: c_int = 0x1 | 0x2; // FREAD | FWRITE
            _ = std.c.ioctl(master, TIOC.FLUSH, &queues);
        },
        .linux => _ = std.c.ioctl(master, TIOC.FLUSH, @as(c_int, 2)), // TCIOFLUSH
        else => {},
    }
}

/// Blocks until the child exits but leaves it a zombie, so its PID cannot be
/// recycled before the caller has published that the exit was observed.
fn waitObserve(pid: std.c.pid_t) !void {
    var info: std.c.siginfo_t = undefined;
    while (true) {
        const result = waitid(
            WAITID.P_PID,
            @intCast(pid),
            &info,
            WAITID.WEXITED | WAITID.WNOWAIT,
        );
        if (result == 0) {
            switch (info.code) {
                CLD.EXITED, CLD.KILLED, CLD.DUMPED => return,
                else => {
                    // macOS delivers stop and continue reports here even
                    // though the options ask only for exits, and WNOWAIT
                    // leaves the report pending, so the same call would spin.
                    // Consume the report, then keep waiting for the exit.
                    _ = waitid(
                        WAITID.P_PID,
                        @intCast(pid),
                        &info,
                        WAITID.WSTOPPED | WAITID.WCONTINUED | WAITID.WNOHANG,
                    );
                    continue;
                },
            }
        }
        switch (std.posix.errno(result)) {
            .INTR => continue,
            .CHILD => return error.NoSuchChild,
            else => return error.WaitpidFailed,
        }
    }
}

fn waitPid(pid: std.c.pid_t) !Exit {
    var child_status: c_int = undefined;
    while (true) {
        const result = std.c.waitpid(pid, &child_status, 0);
        if (result > 0) break;

        switch (std.posix.errno(result)) {
            .INTR => continue,
            .CHILD => return error.NoSuchChild,
            else => return error.WaitpidFailed,
        }
    }

    const status: u32 = @bitCast(child_status);
    if (std.posix.W.IFEXITED(status))
        return .{ .exited = std.posix.W.EXITSTATUS(status) };
    if (std.posix.W.IFSIGNALED(status))
        return .{ .signaled = std.posix.W.TERMSIG(status) };
    return error.UnexpectedChildStatus;
}

test "zero-sized hosts still create a valid terminal" {
    const size: Size = .{ .cols = 0, .rows = 0 };
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 24 }, size.valid());
}

test "command arguments remain null terminated" {
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 7" };
    const command = try Command.fromArgv(&args);

    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.file));
    try std.testing.expectEqualStrings("exit 7", std.mem.span(command.argv[2].?));
    try std.testing.expectEqual(@as(?[*:0]const u8, null), command.argv[3]);
}

test "terminal child environment removes inherited Ghostty identity" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();
    try inherited_map.put("HOME", "/tmp/telar-home");
    try inherited_map.put("PATH", "/bin:/usr/bin");
    try inherited_map.put("TERM", "xterm-ghostty");
    try inherited_map.put("TERM_PROGRAM", "ghostty");
    try inherited_map.put("TELAR_SOCKET", "/tmp/outer-telar.sock");
    try inherited_map.put("GHOSTTY_RESOURCES_DIR", "outer");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try Environment.init(
        std.testing.allocator,
        .{ .block = inherited_block },
        "telar",
    );
    defer environment.deinit();
    const child: std.process.Environ = .{ .block = environment.block };

    try std.testing.expectEqualStrings(
        "xterm-256color",
        std.process.Environ.getPosix(child, "TERM").?,
    );
    try std.testing.expectEqualStrings(
        "telar",
        std.process.Environ.getPosix(child, "TERM_PROGRAM").?,
    );
    try std.testing.expectEqualStrings(
        "/tmp/telar-home",
        std.process.Environ.getPosix(child, "HOME").?,
    );
    try std.testing.expect(std.process.Environ.getPosix(child, "TELAR_SOCKET") == null);
    try std.testing.expect(std.process.Environ.getPosix(child, "GHOSTTY_RESOURCES_DIR") == null);
}

test "terminal child environment applies bounded proxy overrides" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();
    try inherited_map.put("HTTPS_PROXY", "http://old.invalid");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);
    var environment = try Environment.initWithOverrides(std.testing.allocator, .{ .block = inherited_block }, .{
        .term_program = "telar",
        .overrides = &.{
            .{ .name = "HTTPS_PROXY", .value = "http://127.0.0.1:45100" },
            .{ .name = "TELAR_PROXY_TLS", .value = "1" },
        },
    });
    defer environment.deinit();
    const child: std.process.Environ = .{ .block = environment.block };
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:45100",
        std.process.Environ.getPosix(child, "HTTPS_PROXY").?,
    );
    try std.testing.expectEqualStrings(
        "1",
        std.process.Environ.getPosix(child, "TELAR_PROXY_TLS").?,
    );
}

test "PTY child receives the explicit terminal environment" {
    var inherited_map = std.process.Environ.Map.init(std.testing.allocator);
    defer inherited_map.deinit();
    try inherited_map.put("PATH", "/bin:/usr/bin");
    try inherited_map.put("GHOSTTY_RESOURCES_DIR", "/Applications/Ghostty.app/Contents/Resources");
    const inherited_block = try inherited_map.createPosixBlock(std.testing.allocator, .{});
    defer inherited_block.deinit(std.testing.allocator);

    var environment = try Environment.init(
        std.testing.allocator,
        .{ .block = inherited_block },
        "telar",
    );
    defer environment.deinit();

    const args = [_][*:0]const u8{
        "sh",
        "-c",
        "printf '%s|%s|%s' \"$TERM\" \"$TERM_PROGRAM\" \"${GHOSTTY_RESOURCES_DIR-unset}\"",
    };
    var command = try Command.fromArgv(&args);
    command.environment = &environment;
    var session = try Session.spawn(&command, .{ .cols = 40, .rows = 5 });
    defer session.deinit();

    var output: [128]u8 = undefined;
    const len = try session.file().readStreaming(std.testing.io, &.{&output});
    try std.testing.expectEqual(Exit{ .exited = 0 }, try session.wait());
    try std.testing.expectEqualStrings("xterm-256color|telar|unset", output[0..len]);
}

test "a command accepts the schema's maximum argument count" {
    var args: [max_args][*:0]const u8 = @splat("x");
    args[0] = "/bin/true";
    const command = try Command.fromArgv(&args);
    try std.testing.expectEqualStrings("/bin/true", std.mem.span(command.file));
    try std.testing.expect(command.argv[max_args - 1] != null);
}

test "spawn rejects an invalid working directory before forking" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrintZ(
        &path_buffer,
        "{s}/missing",
        .{directory_buffer[0..directory_len]},
    );
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 0" };
    var command = try Command.fromArgv(&args);
    command.cwd = missing.ptr;
    try std.testing.expectError(
        error.InvalidWorkingDirectory,
        Session.spawn(&command, .{ .cols = 20, .rows = 5 }),
    );
}

test "one argument past the limit is rejected" {
    const args: [max_args + 1][*:0]const u8 = @splat("x");
    try std.testing.expectError(error.TooManyArguments, Command.fromArgv(&args));
}

test "wait reaps a real child once and shutdown after the reap is harmless" {
    const args = [_][*:0]const u8{ "/bin/sh", "-c", "exit 3" };
    const command = try Command.fromArgv(&args);
    var session = try Session.spawn(&command, .{ .cols = 20, .rows = 5 });
    const exit = try session.wait();
    try std.testing.expectEqual(Exit{ .exited = 3 }, exit);
    try std.testing.expectError(error.ChildAlreadyReaped, session.wait());
    session.shutdown();
    session.deinit();
}

test "the process result maps to the conventional shell status" {
    try std.testing.expectEqual(@as(u8, 7), (Exit{ .exited = 7 }).code());
    try std.testing.expectEqual(
        @as(u8, 128 + @intFromEnum(std.posix.SIG.TERM)),
        (Exit{ .signaled = .TERM }).code(),
    );
}
