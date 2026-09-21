//! Native editor protocols. No PTY keystrokes, screen heuristics or shell parsing.
const std = @import("std");
const core = @import("telar-core");
const Job = @import("Job.zig");
const expressions = @import("expressions.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

/// Searches only bounded local endpoints and validates remote process identity.
/// Example: `try remote.open(job);`
pub fn open(job: *Job) !void {
    if (job.candidate_count == 0) {
        return;
    }

    switch (core.editor.identify(job.request.editor())) {
        .neovim => try neovim(job),
        .vim => try vim(job),
        .emacs => try emacs(job),
        .unsupported => {},
    }
}

fn neovim(job: *Job) !void {
    if (job.environment.getPosix("XDG_RUNTIME_DIR")) |root| {
        try scan(job, root, true);
    }

    if (job.result.outcome == .opened) {
        return;
    }

    const user = job.environment.getPosix("USER") orelse return;
    // USER is a directory component, never an arbitrary traversal path.
    if (std.mem.findScalar(u8, user, '/') != null or user.len == 0) {
        return;
    }

    var storage: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = job.environment.getPosix("TMPDIR") orelse "/tmp";
    const root = try std.fmt.bufPrint(&storage, "{s}/nvim.{s}", .{ temporary, user });
    try scan(job, root, true);
    if (job.result.outcome != .opened and !std.mem.eql(u8, temporary, "/tmp")) {
        const fallback = try std.fmt.bufPrint(&storage, "/tmp/nvim.{s}", .{user});
        try scan(job, fallback, true);
    }
}

fn scan(job: *Job, root: []const u8, descend: bool) !void {
    if (job.result.outcome == .opened or !ownedPath(root, .directory)) {
        return;
    }

    var directory = std.Io.Dir.cwd().openDir(job.io, root, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer directory.close(job.io);
    var entries = directory.iterate();
    while (job.entries_left > 0 and job.endpoints_left > 0) {
        const entry = try entries.next(job.io) orelse break;
        job.entries_left -= 1;
        var storage: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&storage, "{s}/{s}", .{ root, entry.name }) catch continue;
        if (entry.kind == .directory and descend) {
            try scan(job, path, false);
        } else if (entry.kind == .unix_domain_socket and ownedPath(path, .socket)) {
            job.endpoints_left -= 1;
            if (core.editor.identify(job.request.editor()) == .emacs) {
                try emacsEndpoint(job, path);
            } else if (std.mem.startsWith(u8, entry.name, "nvim.")) {
                try vimEndpoint(job, path);
            }
        }

        if (job.result.outcome == .opened) {
            return;
        }
    }
}

const PathKind = enum { directory, socket };

fn ownedPath(path: []const u8, kind: PathKind) bool {
    if (path.len == 0 or path[0] != '/' or path.len >= std.fs.max_path_bytes) {
        return false;
    }

    var storage: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(storage[0..path.len], path);
    storage[path.len] = 0;
    var stat: c.struct_stat = undefined;
    if (c.lstat(@ptrCast(&storage), &stat) != 0 or stat.st_uid != c.getuid()) {
        return false;
    }

    const expected: c.mode_t = switch (kind) {
        .directory => c.S_IFDIR,
        .socket => c.S_IFSOCK,
    };
    return stat.st_mode & c.S_IFMT == expected and stat.st_mode & 0o022 == 0;
}

fn vim(job: *Job) !void {
    const output = job.command(&.{ job.request.editor(), "--serverlist" }) catch return;
    defer Job.release(output);
    if (output.term != .exited or output.term.exited != 0) {
        return;
    }

    var names = std.mem.tokenizeAny(u8, output.stdout, "\r\n");
    while (names.next()) |name| {
        if (job.endpoints_left == 0 or job.result.outcome == .opened) {
            return;
        }

        job.endpoints_left -= 1;
        try vimEndpoint(job, name);
    }
}

fn vimEndpoint(job: *Job, endpoint: []const u8) !void {
    const server_option = if (core.editor.identify(job.request.editor()) == .neovim) "--server" else "--servername";
    const identity = job.command(&.{ job.request.editor(), server_option, endpoint, "--remote-expr", "getpid() . \"\\n\" . hostname()" }) catch return;
    defer Job.release(identity);
    if (identity.term != .exited or identity.term.exited != 0) {
        return;
    }

    var lines = std.mem.tokenizeAny(u8, identity.stdout, "\r\n");
    const pid = std.fmt.parseInt(u32, lines.next() orelse return, 10) catch return;
    const remote_host = lines.next() orelse return;
    var hostname: [256:0]u8 = @splat(0);
    if (c.gethostname(&hostname, hostname.len) != 0) {
        return;
    }

    const local_host = std.mem.sliceTo(&hostname, 0);
    if (!std.mem.eql(u8, remote_host, local_host)) {
        return;
    }

    const candidate = job.find(pid) orelse return;
    var storage: [expressions.max_bytes]u8 = undefined;
    const expression = try expressions.vim(&storage, .{ .pid = pid, .path = job.request.path(), .hostname = local_host });
    const output = try job.command(&.{ job.request.editor(), server_option, endpoint, "--remote-expr", expression });
    defer Job.release(output);
    if (output.term != .exited or output.term.exited != 0 or !std.mem.eql(u8, std.mem.trim(u8, output.stdout, " \r\n"), "1")) {
        return error.EditorRejectedOpen;
    }

    job.opened(candidate);
}

fn emacs(job: *Job) !void {
    for (job.candidates[0..job.candidate_count]) |*candidate| {
        var pid_storage: [16]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pid_storage, "{d}", .{candidate.process_group});
        const output = job.command(&.{ "/bin/ps", "-p", pid, "-o", "tty=" }) catch continue;
        defer Job.release(output);
        if (output.term != .exited or output.term.exited != 0) {
            continue;
        }

        const name = std.mem.trim(u8, output.stdout, " \r\n");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "?\r\n") != null) {
            continue;
        }

        const tty = std.fmt.bufPrint(&candidate.tty_bytes, "/dev/{s}", .{name}) catch continue;
        candidate.tty_len = @intCast(tty.len);
    }

    // Honor an explicit socket configured for emacsclient before discovery.
    if (job.environment.getPosix("EMACS_SOCKET_NAME")) |socket| {
        if (ownedPath(socket, .socket)) {
            try emacsEndpoint(job, socket);
        }
    }

    var storage: [std.fs.max_path_bytes]u8 = undefined;
    if (job.environment.getPosix("XDG_RUNTIME_DIR")) |root| {
        const directory = try std.fmt.bufPrint(&storage, "{s}/emacs", .{root});
        try scan(job, directory, false);
    }

    if (job.result.outcome == .opened) {
        return;
    }

    const temporary = job.environment.getPosix("TMPDIR") orelse "/tmp";
    const directory = try std.fmt.bufPrint(&storage, "{s}/emacs{d}", .{ temporary, c.getuid() });
    try scan(job, directory, false);
    if (job.result.outcome != .opened and !std.mem.eql(u8, temporary, "/tmp")) {
        const fallback = try std.fmt.bufPrint(&storage, "/tmp/emacs{d}", .{c.getuid()});
        try scan(job, fallback, false);
    }
}

fn emacsEndpoint(job: *Job, endpoint: []const u8) !void {
    var executable_storage: [std.fs.max_path_bytes]u8 = undefined;
    const executable = if (std.fs.path.dirname(job.request.editor())) |directory|
        try std.fmt.bufPrint(&executable_storage, "{s}/emacsclient", .{directory})
    else
        "emacsclient";
    const identity = job.command(&.{ executable, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", "(emacs-pid)" }) catch return;
    defer Job.release(identity);
    if (identity.term != .exited or identity.term.exited != 0) {
        return;
    }

    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, identity.stdout, " \r\n"), 10) catch return;
    var hostname: [256:0]u8 = @splat(0);
    if (c.gethostname(&hostname, hostname.len) != 0) {
        return;
    }

    for (job.candidates[0..job.candidate_count]) |candidate| {
        if (candidate.tty_len == 0) {
            continue;
        }

        var storage: [expressions.max_bytes]u8 = undefined;
        const expression = try expressions.emacs(&storage, .{ .pid = pid, .path = job.request.path(), .tty = candidate.tty(), .hostname = std.mem.sliceTo(&hostname, 0) });
        const output = try job.command(&.{ executable, "--alternate-editor=/usr/bin/false", "--socket-name", endpoint, "--eval", expression });
        defer Job.release(output);
        if (output.term != .exited or output.term.exited != 0) {
            return error.EditorRejectedOpen;
        }

        const result = std.mem.trim(u8, output.stdout, " \r\n");
        if (std.mem.eql(u8, result, "1")) {
            job.opened(candidate);
            return;
        } else if (!std.mem.eql(u8, result, "0")) {
            return error.EditorRejectedOpen;
        }
    }
}
