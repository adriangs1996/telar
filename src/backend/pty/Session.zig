const std = @import("std");
const Command = @import("Command.zig");
const Size = @import("Size.zig");
const session_support = @import("session_support.zig");
const spawn_mod = @import("spawn.zig");
const native = @import("native.zig");
const exit_module = @import("exit.zig");
/// The process and PTY master owned by one runtime pane.
const Session = @This();

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
pub fn spawn(command: *const Command, initial_size: Size) !Session {
    var window = session_support.windowSize(initial_size);
    const spawned = try spawn_mod.spawn(command, &window);
    return .{ .master = spawned.master, .pid = spawned.pid };
}

/// Returns the process identifier of the session leader.
///
/// ```zig
/// const pid = session.processId();
/// ```
pub fn processId(self: *const Session) std.c.pid_t {
    return self.pid;
}

/// Reads child output, then drains only bytes already available. A burst
/// occupies at most the caller's buffer and eight reads, preserving a short
/// response without waiting for future output. One actor owns the read side.
///
/// ```zig
/// const len = try session.read(io, &buffer);
/// ```
pub fn read(self: *const Session, io: std.Io, buffer: []u8) !usize {
    const input = self.file();
    var len = try input.readStreaming(io, &.{buffer});
    var reads: usize = 1;

    while (len != 0 and len < buffer.len and reads < 8 and native.outputReady(self.master)) : (reads += 1) {
        const extra = input.readStreaming(io, &.{buffer[len..]}) catch |err| switch (err) {
            error.Canceled => return err,
            else => break,
        };
        if (extra == 0) {
            break;
        }

        len += extra;
    }

    return len;
}

/// Writes the complete input slice to the child through the PTY master.
///
/// ```zig
/// try session.writeAll(io, "git status\n");
/// ```
pub fn writeAll(self: *const Session, io: std.Io, bytes: []const u8) !void {
    return self.file().writeStreamingAll(io, bytes);
}

fn file(self: *const Session) std.Io.File {
    return .{
        .handle = self.master,
        .flags = .{ .nonblocking = false },
    };
}

/// Returns whether the session leader currently owns the terminal. A
/// foreground job gets a different process group, regardless of shell.
///
/// ```zig
/// const shell_is_foreground = session.shellForeground() orelse false;
/// ```
pub fn shellForeground(self: *const Session) ?bool {
    if (self.master < 0) {
        return null;
    }

    const foreground = native.foregroundProcessGroup(self.master) orelse return null;
    return foreground == self.pid;
}

/// Returns the foreground process group controlling the slave side. The
/// observation worker uses this constant-cost signal before inspecting
/// any native process metadata.
///
/// ```zig
/// const process_group = session.foregroundProcessGroup() orelse return;
/// ```
pub fn foregroundProcessGroup(self: *const Session) ?std.c.pid_t {
    if (self.master < 0) {
        return null;
    }

    return native.foregroundProcessGroup(self.master);
}

/// Resizing the master updates the kernel's PTY state and sends SIGWINCH
/// to the foreground process group on the slave side.
///
/// ```zig
/// try session.resize(size);
/// ```
pub fn resize(self: *Session, next_size: Size) !void {
    var window = session_support.windowSize(next_size);
    try native.setWindowSize(self.master, &window);
}

/// Blocks until the child exits, reaps it exactly once, and returns its
/// terminal status. One caller owns the wait. A concurrent call returns
/// `ChildWaitAlreadyClaimed`; a later call returns `ChildAlreadyReaped`.
///
/// ```zig
/// const exit = try session.wait();
/// ```
pub fn wait(self: *Session) !exit_module.Exit {
    if (self.deinitialized.load(.acquire)) {
        return error.ChildAlreadyReaped;
    }

    if (self.wait_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        if (self.reaped.load(.acquire)) {
            return error.ChildAlreadyReaped;
        }

        return error.ChildWaitAlreadyClaimed;
    }

    self.lockLifecycle();
    if (self.reaped.load(.acquire)) {
        self.unlockLifecycle();
        return error.ChildAlreadyReaped;
    }
    self.unlockLifecycle();

    // The blocking observation happens outside the mutex so shutdown can
    // still terminate a running child. Once the child is a zombie, wait
    // and shutdown serialize the decision to reap or signal it.
    try native.waitObserve(self.pid);

    self.lockLifecycle();
    defer self.unlockLifecycle();
    if (self.reaped.load(.acquire)) {
        return error.ChildAlreadyReaped;
    }

    const exit = try native.waitPid(self.pid);
    self.reaped.store(true, .release);
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
pub fn shutdown(self: *Session) void {
    if (self.deinitialized.load(.acquire)) {
        return;
    }

    self.lockLifecycle();
    defer self.unlockLifecycle();

    if (!self.reaped.load(.acquire)) {
        native.terminateForeground(self.master);

        native.terminate(self.pid);
        // Discard queued terminal I/O before joining the wait actor.
        // The master stays open until all descriptor borrows finish.
        native.flushPty(self.master);
    }
}

fn closeMaster(self: *Session) void {
    if (self.master >= 0) {
        // A master write blocked on a full slave input queue survives
        // even the child's death, and Darwin's close then waits behind
        // it forever. Flushing both queues wakes the writer first.
        native.flushPty(self.master);
        native.closeDescriptor(&self.master);
    }
}

fn lockLifecycle(self: *Session) void {
    const result = std.c.pthread_mutex_lock(&self.lifecycle_mutex);
    std.debug.assert(result == .SUCCESS);
}

fn unlockLifecycle(self: *Session) void {
    const result = std.c.pthread_mutex_unlock(&self.lifecycle_mutex);
    std.debug.assert(result == .SUCCESS);
}

/// Closes the PTY and reaps a child that was not already collected.
/// Callers must first join operations using this session. Repeated calls
/// are harmless.
///
/// ```zig
/// session.deinit();
/// ```
pub fn deinit(self: *Session) void {
    if (self.deinitialized.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return;
    }

    self.closeMaster();

    self.lockLifecycle();
    if (!self.reaped.load(.acquire)) {
        native.terminate(self.pid);
        _ = native.waitPid(self.pid) catch {};
        self.reaped.store(true, .release);
    }
    self.unlockLifecycle();

    const result = std.c.pthread_mutex_destroy(&self.lifecycle_mutex);
    std.debug.assert(result == .SUCCESS);
}
