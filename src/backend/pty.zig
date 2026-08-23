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
    },
    .linux => struct {
        const SWINSZ: c_int = 0x5414;
        const SCTTY: c_int = 0x540E;
    },
    else => @compileError("telar's PTY bootstrap currently supports macOS and Linux"),
};

extern "c" fn openpty(
    amaster: *std.c.fd_t,
    aslave: *std.c.fd_t,
    name: ?[*]u8,
    termp: ?*const std.posix.termios,
    winp: ?*const std.posix.winsize,
) c_int;

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;

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

    pub fn fromArgv(args: []const [*:0]const u8) !Command {
        if (args.len == 0) return error.MissingCommand;
        if (args.len >= max_args) return error.TooManyArguments;

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

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) childExec(master, slave, command);

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

        const result = try waitPid(session.pid);
        session.reaped.store(true, .release);
        return result;
    }

    /// Make every blocking operation on the session able to finish.
    ///
    /// The runtime calls this before cancelling its actors: `waitpid` is a
    /// blocking libc call and cannot be cancelled by `Io.Select`, so the child
    /// has to be terminated before the actor waiting for it can be joined.
    pub fn shutdown(session: *Session) void {
        // Signal first. On Darwin, close can itself wait for an in-flight read
        // on this descriptor; killing the session leader releases both that
        // read and the actor blocked in waitpid.
        if (!session.reaped.load(.acquire)) _ = std.c.kill(session.pid, .KILL);
        session.closeMaster();
    }

    fn closeMaster(session: *Session) void {
        if (session.master >= 0) {
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
fn childExec(
    master: std.c.fd_t,
    slave: std.c.fd_t,
    command: *const Command,
) noreturn {
    if (std.c.setsid() < 0) std.c._exit(1);
    if (std.c.ioctl(slave, TIOC.SCTTY, @as(c_int, 0)) != 0) std.c._exit(1);

    if (std.c.dup2(slave, std.c.STDIN_FILENO) < 0) std.c._exit(1);
    if (std.c.dup2(slave, std.c.STDOUT_FILENO) < 0) std.c._exit(1);
    if (std.c.dup2(slave, std.c.STDERR_FILENO) < 0) std.c._exit(1);

    _ = std.c.close(master);
    if (slave > std.c.STDERR_FILENO) _ = std.c.close(slave);
    if (command.cwd) |cwd| {
        if (std.c.chdir(cwd) != 0) std.c._exit(126);
    }

    _ = execvp(command.file, &command.argv);
    std.c._exit(127);
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

test "the process result maps to the conventional shell status" {
    try std.testing.expectEqual(@as(u8, 7), (Exit{ .exited = 7 }).code());
    try std.testing.expectEqual(
        @as(u8, 128 + @intFromEnum(std.posix.SIG.TERM)),
        (Exit{ .signaled = .TERM }).code(),
    );
}
