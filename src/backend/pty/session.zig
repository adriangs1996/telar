/// The process and PTY master owned by one runtime pane.
const Session = @This();
const std = @import("std");
const source_namespace = @import("session_support.zig");
const Size = @import("Size.zig");
const spawn_mod = @import("spawn.zig");
const native = @import("native.zig");
master: std.c.fd_t,
pid: std.c.pid_t,
wait_claimed: std.atomic.Value(bool) = .init(false),
reaped: std.atomic.Value(bool) = .init(false),
deinitialized: std.atomic.Value(bool) = .init(false),
lifecycle_mutex: std.c.pthread_mutex_t = .{},

/// Creates a PTY-backed child and returns only after `execve` succeeds.
/// The command and its borrowed strings may be released after this call.
///
/// ```zig
/// var session = try Session.spawn(&command, .{ .cols = 80, .rows = 24 });
/// defer session.deinit();
/// ```
pub fn spawn(command: *const source_namespace.Command, initial_size: Size) !Session {
    var window = source_namespace.windowSize(initial_size);
    const spawned = try spawn_mod.spawn(command, &window);
    return .{ .master = spawned.master, .pid = spawned.pid };
}

/// Returns the process identifier of the session leader.
///
/// ```zig
/// const pid = session.processId();
/// ```
pub fn processId(session: *const Session) std.c.pid_t {
    return session.pid;
}

/// Reads child output from the PTY master into the caller's buffer.
///
/// ```zig
/// const len = try session.read(io, &buffer);
/// ```
pub fn read(session: *const Session, io: std.Io, buffer: []u8) !usize {
    return session.file().readStreaming(io, &.{buffer});
}

/// Writes the complete input slice to the child through the PTY master.
///
/// ```zig
/// try session.writeAll(io, "git status\n");
/// ```
pub fn writeAll(session: *const Session, io: std.Io, bytes: []const u8) !void {
    return session.file().writeStreamingAll(io, bytes);
}

fn file(session: *const Session) source_namespace.File {
    return .{
        .handle = session.master,
        .flags = .{ .nonblocking = false },
    };
}

/// Returns whether the session leader currently owns the terminal. A
/// foreground job gets a different process group, regardless of shell.
///
/// ```zig
/// const shell_is_foreground = session.shellForeground() orelse false;
/// ```
pub fn shellForeground(session: *const Session) ?bool {
    if (session.master < 0) {
        return null;
    }

    const foreground = native.foregroundProcessGroup(session.master) orelse return null;
    return foreground == session.pid;
}

/// Returns the foreground process group controlling the slave side. The
/// observation worker uses this constant-cost signal before inspecting
/// any native process metadata.
///
/// ```zig
/// const process_group = session.foregroundProcessGroup() orelse return;
/// ```
pub fn foregroundProcessGroup(session: *const Session) ?std.c.pid_t {
    if (session.master < 0) {
        return null;
    }

    return native.foregroundProcessGroup(session.master);
}

/// Resizing the master updates the kernel's PTY state and sends SIGWINCH
/// to the foreground process group on the slave side.
///
/// ```zig
/// try session.resize(size);
/// ```
pub fn resize(session: *Session, next_size: Size) !void {
    var window = source_namespace.windowSize(next_size);
    try native.setWindowSize(session.master, &window);
}

/// Blocks until the child exits, reaps it exactly once, and returns its
/// terminal status. One caller owns the wait. A concurrent call returns
/// `ChildWaitAlreadyClaimed`; a later call returns `ChildAlreadyReaped`.
///
/// ```zig
/// const exit = try session.wait();
/// ```
pub fn wait(session: *Session) !source_namespace.Exit {
    if (session.deinitialized.load(.acquire)) {
        return error.ChildAlreadyReaped;
    }

    if (session.wait_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        if (session.reaped.load(.acquire)) {
            return error.ChildAlreadyReaped;
        }

        return error.ChildWaitAlreadyClaimed;
    }

    session.lockLifecycle();
    if (session.reaped.load(.acquire)) {
        session.unlockLifecycle();
        return error.ChildAlreadyReaped;
    }
    session.unlockLifecycle();

    // The blocking observation happens outside the mutex so shutdown can
    // still terminate a running child. Once the child is a zombie, wait
    // and shutdown serialize the decision to reap or signal it.
    try native.waitObserve(session.pid);

    session.lockLifecycle();
    defer session.unlockLifecycle();
    if (session.reaped.load(.acquire)) {
        return error.ChildAlreadyReaped;
    }

    const exit = try native.waitPid(session.pid);
    session.reaped.store(true, .release);
    return exit;
}

/// Makes every blocking operation on the session able to finish.
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
///
/// ```zig
/// session.shutdown();
/// ```
pub fn shutdown(session: *Session) void {
    if (session.deinitialized.load(.acquire)) {
        return;
    }

    session.lockLifecycle();
    defer session.unlockLifecycle();

    if (!session.reaped.load(.acquire)) {
        native.terminateForeground(session.master);

        native.terminate(session.pid);
        // Discard queued terminal I/O before joining the wait actor.
        // The master stays open until all descriptor borrows finish.
        native.flushPty(session.master);
    }
}

fn closeMaster(session: *Session) void {
    if (session.master >= 0) {
        // A master write blocked on a full slave input queue survives
        // even the child's death, and Darwin's close then waits behind
        // it forever. Flushing both queues wakes the writer first.
        native.flushPty(session.master);
        native.closeDescriptor(&session.master);
    }
}

fn lockLifecycle(session: *Session) void {
    const result = std.c.pthread_mutex_lock(&session.lifecycle_mutex);
    std.debug.assert(result == .SUCCESS);
}

fn unlockLifecycle(session: *Session) void {
    const result = std.c.pthread_mutex_unlock(&session.lifecycle_mutex);
    std.debug.assert(result == .SUCCESS);
}

/// Closes the PTY and reaps a child that was not already collected.
/// Callers must first join operations using this session. Repeated calls
/// are harmless.
///
/// ```zig
/// session.deinit();
/// ```
pub fn deinit(session: *Session) void {
    if (session.deinitialized.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }

    session.closeMaster();

    session.lockLifecycle();
    if (!session.reaped.load(.acquire)) {
        native.terminate(session.pid);
        _ = native.waitPid(session.pid) catch {};
        session.reaped.store(true, .release);
    }
    session.unlockLifecycle();

    const result = std.c.pthread_mutex_destroy(&session.lifecycle_mutex);
    std.debug.assert(result == .SUCCESS);
}
