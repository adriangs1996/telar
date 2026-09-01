//! macOS and Linux system-call boundary for PTY sessions.

const std = @import("std");
const builtin = @import("builtin");
const Exit = @import("exit.zig").Exit;

const TIOC = switch (builtin.os.tag) {
    .macos => struct {
        const SWINSZ: c_int = @bitCast(@as(u32, 0x80087467));
        const SCTTY: c_int = 0x20007461;
        const FLUSH: c_int = @bitCast(@as(u32, 0x80047410));
    },
    .linux => struct {
        const SWINSZ: c_int = 0x5414;
        const SCTTY: c_int = 0x540E;
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

const CLD = struct {
    const EXITED: c_int = 1;
    const KILLED: c_int = 2;
    const DUMPED: c_int = 3;
};

extern "c" fn waitid(idtype: c_int, id: c_uint, infop: *std.c.siginfo_t, options: c_int) c_int;
extern "c" fn openpty(amaster: *std.c.fd_t, aslave: *std.c.fd_t, name: ?[*]u8, termp: ?*const std.posix.termios, winp: ?*const std.posix.winsize) c_int;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
extern "c" var environ: [*:null]?[*:0]u8;
extern "c" fn tcgetpgrp(fd: std.c.fd_t) std.c.pid_t;

pub const Pair = struct {
    master: std.c.fd_t,
    slave: std.c.fd_t,
};

pub fn openPty(window: *const std.posix.winsize) !Pair {
    var pair: Pair = .{ .master = -1, .slave = -1 };
    if (openpty(&pair.master, &pair.slave, null, null, window) < 0) {
        return error.OpenPtyFailed;
    }

    return pair;
}

pub fn closeDescriptor(fd: *std.c.fd_t) void {
    if (fd.* < 0) {
        return;
    }

    _ = std.c.close(fd.*);
    fd.* = -1;
}

pub fn setCloseOnExec(fd: std.c.fd_t) !void {
    const result = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    if (result < 0) {
        return error.SetCloseOnExecFailed;
    }
}

pub fn openCloseOnExecPipe() ![2]std.c.fd_t {
    var pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe) < 0) {
        return error.OpenChildErrorPipeFailed;
    }
    errdefer closeDescriptor(&pipe[0]);
    errdefer closeDescriptor(&pipe[1]);

    try setCloseOnExec(pipe[0]);
    try setCloseOnExec(pipe[1]);
    return pipe;
}

pub fn currentEnvironment() [*:null]const ?[*:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => @ptrCast(_NSGetEnviron().*),
        .linux => @ptrCast(environ),
        else => unreachable,
    };
}

pub fn createSession() c_int {
    return std.c.setsid();
}

pub fn acquireControllingTerminal(slave: std.c.fd_t) c_int {
    return std.c.ioctl(slave, TIOC.SCTTY, @as(c_int, 0));
}

pub fn foregroundProcessGroup(master: std.c.fd_t) ?std.c.pid_t {
    const foreground = tcgetpgrp(master);
    return if (foreground > 0) foreground else null;
}

pub fn setWindowSize(master: std.c.fd_t, window: *const std.posix.winsize) !void {
    if (std.c.ioctl(master, TIOC.SWINSZ, window) != 0) {
        return error.SetWindowSizeFailed;
    }
}

pub fn flushPty(master: std.c.fd_t) void {
    switch (builtin.os.tag) {
        .macos => {
            var queues: c_int = 0x1 | 0x2;
            _ = std.c.ioctl(master, TIOC.FLUSH, &queues);
        },
        .linux => _ = std.c.ioctl(master, TIOC.FLUSH, @as(c_int, 2)),
        else => {},
    }
}

pub fn waitObserve(pid: std.c.pid_t) !void {
    var info: std.c.siginfo_t = undefined;
    while (true) {
        const result = waitid(WAITID.P_PID, @intCast(pid), &info, WAITID.WEXITED | WAITID.WNOWAIT);
        if (result == 0) {
            switch (info.code) {
                CLD.EXITED, CLD.KILLED, CLD.DUMPED => return,
                else => {
                    _ = waitid(WAITID.P_PID, @intCast(pid), &info, WAITID.WSTOPPED | WAITID.WCONTINUED | WAITID.WNOHANG);
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

pub fn waitPid(pid: std.c.pid_t) !Exit {
    var child_status: c_int = undefined;
    while (true) {
        const result = std.c.waitpid(pid, &child_status, 0);
        if (result > 0) {
            break;
        }

        switch (std.posix.errno(result)) {
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

pub fn terminateAndReap(pid: std.c.pid_t) void {
    terminate(pid);
    _ = waitPid(pid) catch {};
}

pub fn terminate(pid: std.c.pid_t) void {
    _ = std.c.kill(pid, .KILL);
}

test "close-on-exec setup reports invalid descriptors" {
    try std.testing.expectError(error.SetCloseOnExecFailed, setCloseOnExec(-1));
}
