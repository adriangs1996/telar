//! PTY acquisition and the verified fork-to-exec transaction.

const std = @import("std");
const command_mod = @import("command.zig");
const native = @import("native.zig");

const Command = command_mod.Command;
const max_args = command_mod.max_args;

const default_path = "/usr/local/bin:/bin:/usr/bin";

const ChildFailureStage = enum(c_int) {
    session,
    controlling_terminal,
    working_directory,
    stdin,
    stdout,
    stderr,
    exec,
};

const ChildFailure = extern struct {
    stage: ChildFailureStage,
    errno_code: c_int,
};

pub const Spawned = struct {
    master: std.c.fd_t,
    pid: std.c.pid_t,
};

pub fn spawn(command: *const Command, window: *const std.posix.winsize) !Spawned {
    const cwd_fd: ?std.c.fd_t = if (command.cwd) |cwd_path|
        std.posix.openat(std.posix.AT.FDCWD, std.mem.span(cwd_path), .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .DIRECTORY = true,
        }, 0) catch return error.InvalidWorkingDirectory
    else
        null;
    defer {
        if (cwd_fd) |fd| {
            _ = std.c.close(fd);
        }
    }

    var pair = try native.openPty(window);
    errdefer native.closeDescriptor(&pair.master);
    errdefer native.closeDescriptor(&pair.slave);

    // Every retained master must close in later children after exec; otherwise
    // a newly launched pane could inherit access to an older pane's terminal.
    try native.setCloseOnExec(pair.master);
    try native.setCloseOnExec(pair.slave);

    var error_pipe = try native.openCloseOnExecPipe();
    errdefer native.closeDescriptor(&error_pipe[0]);
    errdefer native.closeDescriptor(&error_pipe[1]);

    const child_environment = commandEnvironment(command);
    const path = environmentValue(child_environment, "PATH") orelse default_path;

    const pid = std.c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = std.c.close(error_pipe[0]);
        childExec(.{
            .master = pair.master,
            .slave = pair.slave,
            .cwd_fd = cwd_fd,
            .error_fd = error_pipe[1],
            .command = command,
            .environment = child_environment,
            .path = path,
        });
    }

    var spawned_pid: ?std.c.pid_t = pid;
    errdefer {
        if (spawned_pid) |child_pid| {
            native.terminateAndReap(child_pid);
        }
    }

    native.closeDescriptor(&pair.slave);
    native.closeDescriptor(&error_pipe[1]);
    const child_failure = readChildFailure(error_pipe[0]) catch return error.ChildBootstrapReadFailed;
    native.closeDescriptor(&error_pipe[0]);
    if (child_failure) |failure| {
        return childFailureError(failure);
    }

    spawned_pid = null;
    return .{ .master = pair.master, .pid = pid };
}

fn commandEnvironment(command: *const Command) [*:null]const ?[*:0]const u8 {
    if (command.environment) |environment| {
        return environment.block.slice.ptr;
    }

    return native.currentEnvironment();
}

fn environmentValue(environment: [*:null]const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (environment[index]) |entry| : (index += 1) {
        const bytes = std.mem.span(entry);
        if (bytes.len <= name.len or bytes[name.len] != '=') {
            continue;
        }
        if (!std.mem.eql(u8, bytes[0..name.len], name)) {
            continue;
        }

        return bytes[name.len + 1 ..];
    }

    return null;
}

fn readChildFailure(fd: std.c.fd_t) !?ChildFailure {
    var failure: ChildFailure = undefined;
    const bytes: [*]u8 = @ptrCast(&failure);
    var read_len: usize = 0;

    while (read_len < @sizeOf(ChildFailure)) {
        const result = std.c.read(fd, bytes + read_len, @sizeOf(ChildFailure) - read_len);
        if (result > 0) {
            read_len += @intCast(result);
            continue;
        }
        if (result == 0) {
            return if (read_len == 0) null else error.IncompleteChildFailure;
        }
        if (std.posix.errno(result) == .INTR) {
            continue;
        }

        return error.ReadChildFailureFailed;
    }

    return failure;
}

fn childFailureError(failure: ChildFailure) anyerror {
    const errno: std.posix.E = @enumFromInt(failure.errno_code);
    return switch (failure.stage) {
        .working_directory => error.InvalidWorkingDirectory,
        .exec => switch (errno) {
            .NOENT, .NOTDIR => error.ExecutableNotFound,
            .ACCES, .PERM => error.ExecutableAccessDenied,
            .NOEXEC => error.InvalidExecutable,
            else => error.ExecFailed,
        },
        else => error.ChildSetupFailed,
    };
}

const ChildExec = struct {
    master: std.c.fd_t,
    slave: std.c.fd_t,
    cwd_fd: ?std.c.fd_t,
    error_fd: std.c.fd_t,
    command: *const Command,
    environment: [*:null]const ?[*:0]const u8,
    path: []const u8,
};

/// No allocator, error unwinding, or operation that can acquire a userspace
/// libc lock may run in the child between `fork` and successful `execve`.
fn childExec(child: ChildExec) noreturn {
    const session_result = native.createSession();
    if (session_result < 0) {
        childFail(child.error_fd, .session, std.posix.errno(session_result));
    }
    const terminal_result = native.acquireControllingTerminal(child.slave);
    if (terminal_result != 0) {
        childFail(child.error_fd, .controlling_terminal, std.posix.errno(terminal_result));
    }
    if (child.cwd_fd) |fd| {
        const directory_result = std.c.fchdir(fd);
        if (directory_result != 0) {
            childFail(child.error_fd, .working_directory, std.posix.errno(directory_result));
        }
    }

    duplicateChildDescriptor(.{ .error_fd = child.error_fd, .source = child.slave, .target = std.c.STDIN_FILENO, .stage = .stdin });
    duplicateChildDescriptor(.{ .error_fd = child.error_fd, .source = child.slave, .target = std.c.STDOUT_FILENO, .stage = .stdout });
    duplicateChildDescriptor(.{ .error_fd = child.error_fd, .source = child.slave, .target = std.c.STDERR_FILENO, .stage = .stderr });

    _ = std.c.close(child.master);
    if (child.slave > std.c.STDERR_FILENO) {
        _ = std.c.close(child.slave);
    }

    const exec_error = execWithPath(.{
        .file = child.command.file,
        .argv = &child.command.argv,
        .environment = child.environment,
        .path = child.path,
    });
    childFail(child.error_fd, .exec, exec_error);
}

const ChildDescriptor = struct {
    error_fd: std.c.fd_t,
    source: std.c.fd_t,
    target: std.c.fd_t,
    stage: ChildFailureStage,
};

fn duplicateChildDescriptor(descriptor: ChildDescriptor) void {
    const result = std.c.dup2(descriptor.source, descriptor.target);
    if (result < 0) {
        childFail(descriptor.error_fd, descriptor.stage, std.posix.errno(result));
    }
}

const ExecRequest = struct {
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    path: []const u8,
};

fn execWithPath(request: ExecRequest) std.posix.E {
    const file = std.mem.span(request.file);
    if (std.mem.findScalar(u8, file, '/') != null) {
        return execCandidate(request, request.file);
    }

    var path_buffer: [std.posix.PATH_MAX]u8 = undefined;
    var paths = std.mem.splitScalar(u8, request.path, ':');
    var access_denied = false;
    while (paths.next()) |path_entry| {
        const directory = if (path_entry.len == 0) "." else path_entry;
        const candidate_len = directory.len + 1 + file.len;
        if (candidate_len + 1 > path_buffer.len) {
            return .NAMETOOLONG;
        }

        @memcpy(path_buffer[0..directory.len], directory);
        path_buffer[directory.len] = '/';
        @memcpy(path_buffer[directory.len + 1 ..][0..file.len], file);
        path_buffer[candidate_len] = 0;
        const candidate = path_buffer[0..candidate_len :0].ptr;

        const exec_error = execCandidate(request, candidate);
        switch (exec_error) {
            .ACCES => access_denied = true,
            .NOENT, .NOTDIR => {},
            else => return exec_error,
        }
    }

    return if (access_denied) .ACCES else .NOENT;
}

fn execCandidate(request: ExecRequest, candidate: [*:0]const u8) std.posix.E {
    const result = std.c.execve(candidate, request.argv, request.environment);
    const exec_error = std.posix.errno(result);
    if (exec_error != .NOEXEC) {
        return exec_error;
    }

    var shell_argv: [max_args + 1:null]?[*:0]const u8 = @splat(null);
    shell_argv[0] = "/bin/sh";
    shell_argv[1] = candidate;
    var source_index: usize = 1;
    var destination_index: usize = 2;
    while (request.argv[source_index]) |argument| : (source_index += 1) {
        shell_argv[destination_index] = argument;
        destination_index += 1;
    }

    const shell_result = std.c.execve("/bin/sh", &shell_argv, request.environment);
    return std.posix.errno(shell_result);
}

fn childFail(fd: std.c.fd_t, stage: ChildFailureStage, error_code: std.posix.E) noreturn {
    const failure: ChildFailure = .{
        .stage = stage,
        .errno_code = @intCast(@intFromEnum(error_code)),
    };
    const bytes: [*]const u8 = @ptrCast(&failure);
    var written: usize = 0;
    while (written < @sizeOf(ChildFailure)) {
        const result = std.c.write(fd, bytes + written, @sizeOf(ChildFailure) - written);
        if (result > 0) {
            written += @intCast(result);
            continue;
        }
        if (result < 0 and std.posix.errno(result) == .INTR) {
            continue;
        }

        break;
    }

    std.c._exit(127);
}

test "child failure reports preserve actionable exec errors" {
    try std.testing.expectEqual(
        error.ExecutableNotFound,
        childFailureError(.{ .stage = .exec, .errno_code = @intFromEnum(std.posix.E.NOENT) }),
    );
    try std.testing.expectEqual(
        error.ExecutableAccessDenied,
        childFailureError(.{ .stage = .exec, .errno_code = @intFromEnum(std.posix.E.ACCES) }),
    );
    try std.testing.expectEqual(
        error.ChildSetupFailed,
        childFailureError(.{ .stage = .stdin, .errno_code = @intFromEnum(std.posix.E.BADF) }),
    );
}

test "environment lookup requires the complete variable name" {
    const environment: [2:null]?[*:0]const u8 = .{ "PATH_SUFFIX=wrong", "PATH=/bin" };

    try std.testing.expectEqualStrings("/bin", environmentValue(&environment, "PATH").?);
    try std.testing.expect(environmentValue(&environment, "MISSING") == null);
}
